"""AC-R2: экспорт случаев Онгудая 400 м (12:00, ветер 150°) в формат R1 v1 (docs/contracts/air-cascade.md).

Эталон — tools/research/air3d/air.py (CuPy, float64), тот же путь решения, что у
picard_gpu_refs.py (solve: make + init_background + solve(max_outer=3000) + finalize), но вход собран
из массивов фикстуры tests/atmosphere/fixtures/air_model/picard/ongudai_d400_h12 (hc, H, gam из .bin;
params и profiles — из .json): слоя рельефа data/terrain/ongudai в копиях нет (как в
test_air_picard_gpu.gd, case_ongudai). Упаковка массивов — Pack и порядок из air3d/fixtures.py.

    PY=tools/research/heat_ca/.venv/bin/python
    $PY tools/research/air_cascade/export/export_ongudai.py            # все 4 случая
    $PY tools/research/air_cascade/export/export_ongudai.py u3_heat    # выборочно (u3_mech нужен для сверки поля)

Выход: $AIR_CASCADE_DATA/ongudai/ (по умолчанию ~/data/air_cascade/ongudai/).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from dataclasses import replace
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tools/research/air3d"))
import air as A  # noqa: E402
import fixtures as FX  # noqa: E402  (Pack, G, STATE)

FIX = ROOT / "tests/atmosphere/fixtures/air_model/picard/ongudai_d400_h12"
OUT = Path(os.environ.get("AIR_CASCADE_DATA", "~/data/air_cascade")).expanduser() / "ongudai"
TOL = dict(tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6)
CHECK_EVERY = 10
MAX_OUTER = 3000
CASES = {  # имя → (U10, нагрев)
    "u3_heat": (3.0, True), "u3_mech": (3.0, False), "u0_heat": (0.0, True), "u6_heat": (6.0, True),
}
ITER_TOL = 10
FIELD_TOL = 1e-3     # доля u_scale
THETA_TOL = 0.05     # К


def load_fixture():
    m = json.loads(FIX.with_suffix(".json").read_text())
    raw = np.fromfile(FIX.with_suffix(".bin"), "<f4")
    arr = {k: raw[o:o + n].astype(np.float64) for k, (o, n) in m["arrays"].items()}
    return m, arr


def ref_iters(m, U, heat):
    R = {(r["U10"], r["heat"], r["dtype"]): r["iters"] for r in m["runs"]}
    return R.get((U, heat, "float64"), R.get((U, heat, "float32")))


def git_rev():
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def solve_case(m, arr, U, heat):
    import cupy as cp
    g = A.Grid(m["dx"], m["nx"], m["ny"], m["dz"], m["z_bot"], m["nz"], m["x0"], m["y0"])
    hc = arr["hc"].reshape(g.ny, g.nx)
    zc = g.z_bot + (np.arange(g.nz + 2) - 0.5) * g.dz
    gam_c = arr["gam"]
    case = A.Case(U10=U, wdir=m["wdir"], gam=lambda z: np.interp(np.asarray(z, float), zc, gam_c),
                  z_i=m["z_i"], H=arr["H"].reshape(g.ny, g.nx) if heat else None,
                  label=f"ongudai 12h U{U:g} {m['wdir']:g}° {'' if heat else 'noheat'}".strip())
    pr = m["profiles"][f"{U:g}"]
    prm = replace(A.Params(), alpha=pr["alpha"], max_profile=pr["max_profile"])
    for k, v in m["params"].items():
        assert getattr(prm, k) == v, (k, getattr(prm, k), v)       # фикстура считалась на умолчаниях
    assert abs(prm.dtau_per_m * g.dx - m["dtau_u"]) < 1e-9
    S = A.Air(g, hc, case, prm, dtype=np.float64)
    S.init_background()
    st = S.solve(max_outer=MAX_OUTER, check_every=CHECK_EVERY, **TOL)
    S.finalize()
    cp.cuda.Device().synchronize()
    return S, case, st


def export(name, m, arr, ref_stats):
    U, heat = CASES[name]
    S, case, st = solve_case(m, arr, U, heat)
    NX, NY, NZ = S.shape[2], S.shape[1], S.shape[0]
    G = FX.G
    P = FX.Pack()
    P.add("hc", S.hc)
    for k, a in (("cell", S.cell_np), ("tu", S.tu_np), ("tv", S.tv_np), ("tw", S.tw_np), ("nu_bg", S.nu_np),
                 ("Q", S.Q_np), ("gam", S.gam_np), ("cplz", S.cplz_np), ("sp_u", S.sp_np), ("sp_w", S.spw_np),
                 ("spc", S.spc_np), ("ubg", S.ubg_np), ("vbg", S.vbg_np), ("lam", S.lam_np),
                 ("Kx", S.Kx_np), ("Ky", S.Ky_np), ("Kz", S.Kz_np)):
        P.add(k, np.nan_to_num(np.asarray(a, np.float64)))
    P.add("fixed_u", G(S.fixed_u)); P.add("fixed_v", G(S.fixed_v))
    P.add("b_u", G(S.b_u)); P.add("b_v", G(S.b_v))
    for k in FX.STATE:
        P.add("sol_" + k, np.nan_to_num(np.asarray(G(getattr(S, k)), np.float64)))
    u, v, w, th = S.centers()
    uu, vv, ww, tt = (np.asarray(x, np.float64) for x in (u, v, w, th))
    fin = {"u": uu, "v": vv, "w": ww, "theta": tt}
    res = S.hist[-1]
    t_ref = round(S.wall - S.t_check, 3)
    meta = dict(
        format="ref-case", version=1, case=f"ongudai_d400_{name}",
        dims=[NX, NY, NZ], halo=1, dx=S.g.dx, dz=S.g.dz, z_bot=S.g.z_bot, x0=S.g.x0, y0=S.g.y0,
        nx=S.g.nx, ny=S.g.ny, nz=S.g.nz,
        params={k: getattr(S.prm, k) for k in S.prm.__dataclass_fields__},
        case_params=dict(U10=case.U10, wdir=case.wdir, z_i=case.z_i, U_aloft=S.U_a, label=case.label),
        cd=S.cd, fixed_scale=S.fixed_scale, n_fluid=S.n_fluid, closure=S.closure_info,
        mg_levels_xyz=[list(L["shape"])[::-1] for L in S.mg.levels],
        criterion=dict(tol_mom_rms=TOL["tol_mom"], tol_th_rms=TOL["tol_th"], tol_div_rms=TOL["tol_div"],
                       check_every=CHECK_EVERY),
        solution=dict(status=st, iters=int(S.outer), final_residuals=res,
                      max_speed=float(np.nanmax(np.sqrt(uu ** 2 + vv ** 2 + ww ** 2))),
                      w_range=[float(np.nanmin(ww)), float(np.nanmax(ww))],
                      th_range=[float(np.nanmin(tt)), float(np.nanmax(tt))]),
        history=[dict(it=h["it"], mom_rms=h["mom_rms"], th_rms=h["th_rms"], thd_rms=h["thd_rms"],
                      div_rms=h["div_rms"]) for h in S.hist],
        source=dict(fixture="tests/atmosphere/fixtures/air_model/picard/ongudai_d400_h12", U10=U, heat=heat,
                    dtype="float64", git=git_rev()),
        crop=m["crop"], t_ref_s=t_ref,
        notes="Онгудай 400 м, 12:00, ветер с 150°. Постоянный вход после подготовки Air + решение до критерия + "
              "finalize (sol_*), float64 → float32 LE. Без блоков одной итерации. Вход собран из массивов фикстуры "
              "(hc, H, gam — float32), solve как picard_gpu_refs.solve (taper по умолчанию, graph, max_outer 3000).")
    OUT.mkdir(parents=True, exist_ok=True)
    base = OUT / f"ongudai_d400_{name}"
    arrays = P.arrays
    # запись во временный файл и переименование
    tb, tj = Path(str(base) + ".bin.tmp"), Path(str(base) + ".json.tmp")
    np.concatenate(P.parts).tofile(tb)
    tj.write_text(json.dumps(dict(meta, arrays=arrays), ensure_ascii=False, indent=1))
    os.replace(tb, str(base) + ".bin")
    os.replace(tj, str(base) + ".json")
    size = os.path.getsize(str(base) + ".bin") / 2 ** 20
    ref = ref_iters(m, U, heat)
    print(f"{name}: {st}, iters {S.outer} (fixture {ref}), t_ref {t_ref} s, {size:.1f} MB", flush=True)
    ref_stats[name] = dict(iters=int(S.outer), ref=ref, t=t_ref, mb=size, fields=fin)
    del S


def check_field(m, arr, stats):
    """Поле у старта (crop, центры клеток) u3_heat (+w_mech из u3_mech) против crop_* фикстуры."""
    if "u3_heat" not in stats or "u3_mech" not in stats:
        return None
    c = m["crop"]; n = c["n"]; i0, j0 = c["i0"], c["j0"]
    h, mm = stats["u3_heat"]["fields"], stats["u3_mech"]["fields"]
    mine = dict(u=h["u"], v=h["v"], w_mech=mm["w"], w_conv=h["w"] - mm["w"], theta=h["theta"])
    mine = {k: np.nan_to_num(a)[:, j0:j0 + n, i0:i0 + n].astype("<f4").astype(np.float64) for k, a in mine.items()}
    us = m["u_scale"]
    out = {}
    for k, a in mine.items():
        ref = arr["crop_" + k].reshape(a.shape)
        d = float(np.max(np.abs(a - ref)))
        out[k] = dict(max_abs=d, rel=d / us if k != "theta" else None)
    ok = all(v["rel"] <= FIELD_TOL for k, v in out.items() if k != "theta") and out["theta"]["max_abs"] <= THETA_TOL
    return out, ok, us


def main():
    names = sys.argv[1:] or list(CASES)
    m, arr = load_fixture()
    stats = {}
    for nme in names:
        export(nme, m, arr, stats)
    print("\ncase           iters  fixture  diff  t_ref_s   MB")
    bad = False
    for nme, s in stats.items():
        d = abs(s["iters"] - s["ref"])
        bad |= d > ITER_TOL
        print(f"{nme:13s} {s['iters']:6d} {s['ref']:8d} {d:5d} {s['t']:8.2f} {s['mb']:6.1f}")
    fc = check_field(m, arr, stats)
    if fc:
        out, ok, us = fc
        print(f"\nполе у старта (crop {m['crop']}), u_scale {us:.3f}:")
        for k, v in out.items():
            print(f"  {k:7s} max|Δ| {v['max_abs']:.3e}" + (f"  /u_scale {v['rel']:.2e}" if v["rel"] is not None else "  К"))
        print("  допуск: ≤ 1e-3·u_scale, θ′ ≤ 0,05 К →", "OK" if ok else "FAIL")
        bad |= not ok
    print("max_iter_diff=%d" % max(abs(s["iters"] - s["ref"]) for s in stats.values()))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
