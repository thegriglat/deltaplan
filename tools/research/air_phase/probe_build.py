#!/usr/bin/env python3
"""AP-15: план малых проб ap_probe (P2 v6, серия PROBE) и его прогон (P3 + трассы каждой итерации).

  probe_build.py plan  [--name ap_probe] [--out $AIR_SYNTH_DATA/phase] [--tight]   # --tight — дозамер ветви (ap_probe_t)
  probe_build.py run   [--plan DIR] [--variant branch,lam,dumax] [--batch B]
  probe_build.py check                    # CHECK_EVERY = 1 не меняет траекторию (побитно против пачек по 10)

Три пробы (variant линии — branch | dumax | lam), постоянные — как plan_build (N = 0,01 над z_i, α, max_profile, место):
  * branch — уступ STEP_UP, H = 0, h/z_i = 1, s 0,15 и 0,3, Fr 0,85 / 0,9 / 0,95: холодный старт (COLD), тёплый снизу
    (WARM_PREV UP, цепочка 0,5 → 0,95) и тёплый сверху (WARM_PREV DOWN, 1,3 → 0,85); абсолютный критерий в 10 раз строже
    (tol 2e-6 м/с², θ и ∇·u — в том же отношении), max_outer 3000, late 2000/50.
  * dumax — хребет s 0,3, h 500 (ideal_v2, как AP-13), H = 0, h/z_i = 1, холодный старт, 3000 итераций, ω = 1:
    (U_sat 6, N 0,0167), (U_sat 6, N 0,019), (U_sat 3, N 0,0105) — выше порога N_c долгого счёта AP-13 (0,0152 и 0,0093)
    в 1,10 / 1,25 / 1,13 раза. В плане snap_step = 1 (метрики каждой итерации); прогон считает их своим _Job
    (CHECK_EVERY = 1): du1 = max|x_t − x_{t−1}| по u, v, w, невязка, полные колонны u, v, w, θ′ в 6 точках по ветру —
    каждую итерацию, в `<results>/probe/case-<id>.h5`; снимки полей P3 (25 и 600 м) — каждые FIELD_STEP итераций.
  * lam — окно 100 м (перенос 2-го порядка), как SEPARATION ap_v1 (h/z_i = 0,3, H = 0, Fr 3, ветер 270°):
    хребет s 0,3 и 0,5 при λ 40 / 80 / 160 м, уступ вниз STEP_DOWN s 0,5 при 40 / 160 м (Numerics.lam_m, P4 v5).

Прогон — run_phase.Runner (P5: части P3, тёплые цепочки, ckpt), с двумя добавками без правки run_phase/phase_io
(их правит AP-14): серия PROBE в порядке счёта и lam_m в Numerics. GPU — под замком: dp job --lock gpu.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
from dataclasses import replace
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import plan_build as PB    # noqa: E402  (общие постоянные и функции плана; сам файл не трогаем)

pb = PB.pb
R = PB.R
CONTRACT = "P2 v6"
NAME = "ap_probe"
TOL_STRICT = 2e-6                      # 10 × строже абсолютного порога 2e-5 м/с²
FIELD_STEP = 10                        # dumax: снимки полей P3 каждые 10 итераций (метрики — каждую)

BR_S = (0.15, 0.3)
BR_FR = (0.85, 0.9, 0.95)
BR_UP = (0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95)
BR_DOWN = (1.3, 1.2, 1.1, 1.0, 0.95, 0.9, 0.85)
BR_NUM = dict(criterion=pb.ABSOLUTE, tol=TOL_STRICT, max_outer=3000, late_from=2000)
# дозамер (план ap_probe_t, --tight): у s 0,3, Fr 0,9 пара up–down при tol 2e-6 на грани критерия ветви и сжалась против
# tol 2e-5 лишь в 2,3 раза — ещё в 10 раз строже, Fr 0,9 (цепочки до 0,9): упадёт ли расхождение снова
TIGHT_NAME = "ap_probe_t"
BR_TIGHT_NUM = dict(criterion=pb.ABSOLUTE, tol=TOL_STRICT / 10, max_outer=6000, late_from=5000)

DM_POINTS = ((6.0, 0.0167), (6.0, 0.019), (3.0, 0.0105))   # (U_sat, N)
DM_NUM = dict(max_outer=3000, late_from=2000, snap_step=1)
# колонны dumax: x (м, по ветру от гребня; ветер 270° — на восток), y = +200 м; центры клеток 400 м: x_i = −19000 + 400 i
DM_COLS_X = (-5000.0, -3000.0, -1000.0, 200.0, 2200.0, 6200.0)
DM_COL_J = 48

LAM_CASES = (("ridge", 0.3, (40.0, 80.0, 160.0)), ("ridge", 0.5, (40.0, 80.0, 160.0)), ("step_down", 0.5, (40.0, 160.0)))
LAM_FR = 3.0
LAM_NUM = dict(dx_m=100.0, advection_order=2)


def col_index(x):
    return int(round((x + 19000.0) / 400.0))


def build_plan(name=NAME, out=None, write=True, quiet=False, tight=False):
    out = out or os.path.join(PB.data_root(), "phase")
    plan = pb.Plan(contract=CONTRACT, name=name, created=datetime.datetime.now().isoformat(timespec="seconds"),
                   git_commit=PB.git_commit(), command=" ".join(["probe_build.py"] + sys.argv[1:]))
    c = plan.context
    c.lat, c.lon, c.month, c.day, c.hour_local, c.utc_offset = (PB.CTX[k] for k in ("lat", "lon", "month", "day", "hour_local", "utc_offset"))
    c.alpha, c.max_profile, c.base_m, c.h_m = PB.ALPHA, PB.MAX_PROFILE, PB.BASE_M, PB.H_M

    v1 = {sp: i for i, sp in enumerate(PB.ideal_specs())}
    pid = {}

    def relief_v1(sh, s):
        if (sh, s) not in pid:
            r = plan.reliefs.add()
            r.relief_id = len(plan.reliefs) - 1
            r.corpus_relief_id, r.name, r.shape, r.slope, r.h_m = v1[(sh, s)], R.ideal_name(sh, s, PB.LENGTH_M), PB.SHAPE_ENUM[sh], s, PB.H_M
            r.a_m = float(R.ideal_scale_a(sh, s, PB.H_M))
            r.length_m = PB.LENGTH_M if sh == "ridge" else 0.0
            r.corpus = "corpus/ideal_v1"
            pid[(sh, s)] = r.relief_id
        return pid[(sh, s)]

    def relief_v2(sh, s, h):
        key = ("v2", sh, s, h)
        if key not in pid:
            fid = {x: i for i, x in enumerate(PB.fixed_u_relief_specs())}
            r = plan.reliefs.add()
            r.relief_id = len(plan.reliefs) - 1
            r.corpus_relief_id, r.name, r.shape, r.slope, r.h_m = fid[(sh, s, h)], PB.ideal_v2_name(sh, s, h), PB.SHAPE_ENUM[sh], s, h
            r.a_m = float(R.ideal_scale_a(sh, s, h))
            r.length_m = PB.LENGTH_M if sh == "ridge" else 0.0
            r.corpus = PB.CORPUS_V2
            pid[key] = r.relief_id
        return pid[key]

    state = dict(line=0, case=0)
    info = []

    def add(relief_id, H, hz, fr, start, variant, direction=pb.DIR_NONE, ref=-1, n_bv=PB.N_BV, **num):
        ln = plan.lines.add()
        ln.line_id, ln.series, ln.relief_id = state["line"], pb.PROBE, relief_id
        ln.heat_flux_wm2, ln.h_over_zi, ln.n_bv_s, ln.wdir_from_deg = H, hz, n_bv, PB.WDIR
        d = dict(PB.NUM_DEF, lam_m=40.0)
        d.update(num)
        for k, v in d.items():
            setattr(ln.numerics, k, v)
        ln.conditions, ln.cond_id = "", -1
        ln.start, ln.direction, ln.ref_line_id, ln.variant = start, direction, ref, variant
        ln.fr_f64 = np.asarray(fr, "<f8").tobytes()
        ln.first_case_id = state["case"]
        state["line"] += 1
        state["case"] += len(fr)
        return ln

    for s in (BR_S if tight else ()):
        rid = relief_v1("step_up", s)
        cold = add(rid, 0.0, 1.0, [0.9], pb.COLD, "branch", **BR_TIGHT_NUM)
        info.append(dict(variant="branch", line_id=cold.line_id, shape="step_up", s=s, chain="cold"))
        for fr, dr, nm in ((BR_UP[:-1], pb.UP, "up"), (BR_DOWN[:-1], pb.DOWN, "down")):
            ln = add(rid, 0.0, 1.0, fr, pb.WARM_PREV, "branch", direction=dr, ref=cold.line_id, **BR_TIGHT_NUM)
            info.append(dict(variant="branch", line_id=ln.line_id, shape="step_up", s=s, chain=nm))
    for s in (() if tight else BR_S):
        rid = relief_v1("step_up", s)
        cold = add(rid, 0.0, 1.0, BR_FR, pb.COLD, "branch", **BR_NUM)
        info.append(dict(variant="branch", line_id=cold.line_id, shape="step_up", s=s, chain="cold"))
        for fr, dr, nm in ((BR_UP, pb.UP, "up"), (BR_DOWN, pb.DOWN, "down")):
            ln = add(rid, 0.0, 1.0, fr, pb.WARM_PREV, "branch", direction=dr, ref=cold.line_id, **BR_NUM)
            info.append(dict(variant="branch", line_id=ln.line_id, shape="step_up", s=s, chain=nm))
    for u, n in (() if tight else DM_POINTS):
        rid = relief_v2("ridge", PB.FU_S, PB.H_M)
        fr = u / (n * PB.H_M)
        ln = add(rid, 0.0, 1.0, [fr], pb.COLD, "dumax", n_bv=n, **DM_NUM)
        info.append(dict(variant="dumax", line_id=ln.line_id, shape="ridge", s=PB.FU_S, u_sat=u, n_bv=n, fr=fr,
                         cols_x_m=list(DM_COLS_X), cols_i=[col_index(x) for x in DM_COLS_X], col_j=DM_COL_J))
    for sh, s, lams in (() if tight else LAM_CASES):
        rid = relief_v1(sh, s)
        ref = -1
        for lam in lams:
            ln = add(rid, 0.0, 0.3, [LAM_FR], pb.COLD, "lam", ref=ref, lam_m=lam, **LAM_NUM)
            ref = ln.line_id if ref < 0 else ref
            info.append(dict(variant="lam", line_id=ln.line_id, shape=sh, s=s, lam_m=lam))
    plan.n_cases = state["case"]
    table = {}
    for ln in plan.lines:
        t = table.setdefault(ln.variant, [0, 0])
        t[0] += 1
        t[1] += len(ln.fr_f64) // 8
    if write:
        d = Path(out) / name
        d.mkdir(parents=True, exist_ok=True)
        tmp = d / "plan.pb.tmp"
        tmp.write_bytes(plan.SerializeToString())
        os.replace(tmp, d / "plan.pb")
        js = PB.plan_to_json(plan)
        js["probe_selection"] = info
        tmp = d / "plan.json.tmp"
        tmp.write_text(json.dumps(js, ensure_ascii=False, indent=1))
        os.replace(tmp, d / "plan.json")
    if not quiet:
        print(f"план {name}: линий {len(plan.lines)}, случаев {plan.n_cases} (серия PROBE)")
        for v, (nl, nc) in table.items():
            print(f"  {v:<7} линий {nl:>3}  случаев {nc:>3}")
    return plan, info


# ============================================================================== прогон
def _patch_io():
    """Серия PROBE в порядке счёта run_phase (phase_io ещё не знает её; правка phase_io — у AP-14)."""
    import run_phase as RP
    IO = RP.IO
    if "PROBE" not in IO.SERIES_ORDER:
        IO.SERIES_ORDER = tuple(IO.SERIES_ORDER) + ("PROBE",)
        IO.SERIES_RANK = {pb.Series.Value(s): i for i, s in enumerate(IO.SERIES_ORDER)}
    return RP, IO


def make_probe_job(BS):
    """_Job с трассой каждой итерации (нужен BS.CHECK_EVERY = 1): du1, невязка, колонны u, v, w, θ′ (с ореолом)."""

    class ProbeJob(BS._Job):
        def __init__(self, idx, spec, num, init):
            self.p_it, self.p_du, self.p_duu, self.p_res, self.p_cols = [], [], [], [], []
            self.p_prev = None
            self.p_ij = [(DM_COL_J + 1, col_index(x) + 1) for x in DM_COLS_X]
            super().__init__(idx, spec, num, init)

        def _callbacks(self, S, r):
            super()._callbacks(S, r)
            cp = self.cp
            if self.p_prev is not None:
                du_u = float(cp.max(cp.abs(S.u - self.p_prev[0])))
                du = max(du_u, float(cp.max(cp.abs(S.v - self.p_prev[1]))), float(cp.max(cp.abs(S.w - self.p_prev[2]))))
            else:
                du = du_u = float("nan")
            res, _ = self._metric(S, r)
            jj = cp.asarray([j for j, _ in self.p_ij])
            ii = cp.asarray([i for _, i in self.p_ij])
            cols = cp.stack([F[:, jj, ii].T for F in (S.u, S.v, S.w, S.th)], axis=1)     # (ncol, 4, nz+2)
            self.p_it.append(int(r["it"])); self.p_du.append(du); self.p_duu.append(du_u); self.p_res.append(res)
            self.p_cols.append(cols.get().astype(np.float32))
            self.p_prev = (S.u.copy(), S.v.copy(), S.w.copy())

        def _finish_domain(self, status):
            S = self.S
            hc_cols = [float(self.set.hc[j - 1, i - 1]) for j, i in self.p_ij]
            super()._finish_domain(status)
            self.result.meta["probe"] = dict(
                iter=np.asarray(self.p_it, np.int32), du1=np.asarray(self.p_du, np.float32), du1_u=np.asarray(self.p_duu, np.float32),
                resid=np.asarray(self.p_res, np.float32), cols=np.stack(self.p_cols).astype(np.float32),
                cols_x_m=np.asarray(DM_COLS_X), cols_i=np.asarray([i - 1 for _, i in self.p_ij], np.int32), col_j=DM_COL_J,
                hc_cols_m=np.asarray(hc_cols), z_bot_m=float(S.g.z_bot), dz_m=float(S.g.dz), nz=int(S.g.nz),
                u_sat=float(S.U_a))

    return ProbeJob


def write_probe_h5(path, pr, case_id, attrs):
    import h5py
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = str(path) + ".tmp"
    with h5py.File(tmp, "w") as h:
        for k, v in attrs.items():
            h.attrs[k] = v
        h.attrs["case_id"] = int(case_id)
        for k, v in pr.items():
            if isinstance(v, np.ndarray):
                h.create_dataset(k, data=v, compression="gzip", compression_opts=4, shuffle=True)
            else:
                h.attrs[k] = v
        h["cols"].attrs["axes"] = "iter, column, var (u, v, w, theta_prime), k (0 и nz+1 — ореол; центр k: z_bot + (k − 0,5)·dz)"
        h["du1"].attrs["what"] = "max|x_t − x_{t−1}| по u, v, w (сетка решателя), м/с"
    os.replace(tmp, path)


def run(plan_dir, variants, batch=None):
    RP, IO = _patch_io()
    import batch_solver as BS
    plan, _, lines, _, cases = IO.load_plan(plan_dir)

    class ProbeRunner(RP.Runner):
        def _spec(self, c):
            spec, num, ph = super()._spec(c)
            ln = self.lines[c.line_id]
            num = replace(num, lam_m=float(ln.numerics.lam_m) if ln.numerics.lam_m > 0 else 40.0)
            if ln.variant == "dumax":
                num = replace(num, snap_step=FIELD_STEP)
            return spec, num, ph

        def _item(self, c, res, ph, start_cid, sec, m):
            it = super()._item(c, res, ph, start_cid, sec, m)
            pr = (getattr(res, "meta", None) or {}).get("probe")
            if pr is not None:
                write_probe_h5(self.dir / "probe" / f"case-{c.case_id:05d}.h5", pr, c.case_id,
                               dict(plan=str(self.plan_dir), solver_version=self.version, git_commit=IO.git_commit()))
            return it

    rc = 0
    for v in variants:
        ids = [c.case_id for c in cases if lines[c.line_id].variant == v]
        if not ids:
            continue
        r = ProbeRunner(plan_dir, solver=BS, batch=batch, only=ids, inline_writer=True,
                        command=" ".join(["probe_build.py"] + sys.argv[1:]) + f"  [variant {v}]")
        if v == "dumax":
            old = BS.CHECK_EVERY, BS._Job
            BS.CHECK_EVERY, BS._Job = 1, make_probe_job(BS)
            try:
                rc |= r.run()
            finally:
                BS.CHECK_EVERY, BS._Job = old
        else:
            rc |= r.run()
        print(f"{v}: rc {rc}, каталог {r.dir}", flush=True)
    return rc


def check_every_bitwise():
    """CHECK_EVERY = 1 (проверка невязок каждую итерацию) против 10: то же поле после 200 итераций? → dict."""
    _patch_io()
    import batch_solver as BS
    sp = BS.CaseSpec(g100=np.asarray(R.ideal_relief("ridge", 0.3, PB.H_M, PB.LENGTH_M, PB.BASE_M)[0], np.float64),
                     ctx=dict(PB.CTX), u10=6.0 / PB.MAX_PROFILE, wdir_from_deg=270.0, alpha=PB.ALPHA,
                     max_profile=PB.MAX_PROFILE, n_bv_s=0.019, z_i_agl_m=PB.H_M, heat_flux_wm2=0.0)
    num = BS.Numerics(max_outer=200, late_from=100, snap_step=10)
    a = BS.solve_batch([sp], num, batch=1)[0]
    old = BS.CHECK_EVERY, BS._Job
    BS.CHECK_EVERY, BS._Job = 1, make_probe_job(BS)
    try:   # пачки по 10 кончаются на 201-й итерации; при проверке каждую итерацию — max_outer = 201, то же число шагов
        b = BS.solve_batch([sp], replace(num, max_outer=int(a.iters)), batch=1)[0]
    finally:
        BS.CHECK_EVERY, BS._Job = old
    st = max(float(np.max(np.abs(a.state[k] - b.state[k]))) for k in ("u", "v", "w", "th", "p"))
    out = dict(iters=(a.iters, b.iters), max_abs_diff_state=st,
               bitwise_state=all(np.array_equal(a.state[k], b.state[k]) for k in a.state),
               probe_n=int(len(b.meta["probe"]["iter"])),
               note="late mean / снимки берутся в моменты проверок (101, 151 … против 100, 150 …) — сравнивается состояние")
    print(json.dumps(out))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan"); p.add_argument("--name", default=NAME); p.add_argument("--out")
    p.add_argument("--tight", action="store_true", help=f"дозамер ветви tol 2e-7 (план {TIGHT_NAME})")
    r = sub.add_parser("run"); r.add_argument("--plan"); r.add_argument("--variant", default="branch,lam,dumax")
    r.add_argument("--batch", type=int)
    sub.add_parser("check")
    a = ap.parse_args(argv)
    if a.cmd == "plan":
        build_plan(TIGHT_NAME if a.tight and a.name == NAME else a.name, a.out, tight=a.tight)
        return 0
    if a.cmd == "check":
        out = check_every_bitwise()
        (HERE / "analysis" / "AP-15").mkdir(parents=True, exist_ok=True)
        (HERE / "analysis" / "AP-15" / "check_every.json").write_text(json.dumps(out, indent=1))
        return 0
    plan_dir = a.plan or os.path.join(PB.data_root(), "phase", NAME)
    if not os.path.exists(os.path.join(plan_dir, "plan.pb")):
        build_plan(os.path.basename(plan_dir), os.path.dirname(plan_dir), tight=os.path.basename(plan_dir) == TIGHT_NAME)
    return run(plan_dir, [v.strip() for v in a.variant.split(",") if v.strip()], a.batch)


if __name__ == "__main__":
    sys.exit(main())
