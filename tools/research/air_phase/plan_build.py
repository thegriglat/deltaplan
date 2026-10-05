#!/usr/bin/env python3
"""AP-2: построитель плана опытов air-phase (контракты P1, P2 v1: docs/contracts/air-phase.md; состав — docs/plan/air-phase.md §2–§3).

  plan_build.py --name ap_v1 --out ~/air_synth_data/phase [--series grid,sweep,relax,separation,eroded,envelope,envelope_real] [--corpus-out DIR]

Пишет `<out>/<name>/plan.pb` (Plan, proto/phase_plan.proto) + `plan.json` (тот же план для людей) и, если нет,
корпус идеальных рельефов S1 `$AIR_SYNTH_DATA/corpus/ideal_v1/` (через corpus_io; все рельефы всех серий, независимо от
--series — id рельефов не зависят от выбора серий). Печатает число линий и случаев по сериям.
Вызывается и из run_phase.py plan (AP-3): `build_plan(...)`.

Физика входа линии: U_sat = Fr·N·h (N = n_bv_s над z_i, h — перепад рельефа), U10 = U_sat / max_profile (профиль притока
как S2 `conditions.derive`: U_sat = U10·max_profile — скорость выше высоты насыщения профиля); alpha, max_profile —
постоянные плана (Context). Пересчёт Fr → U10 — функция `u10_from_fr`.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE / "proto"))
sys.path.insert(0, str(ROOT / "tools/research/air_synth/solver"))
sys.path.insert(0, str(ROOT / "tools/research/air_synth/corpus"))
import phase_plan_pb2 as pb  # noqa: E402
import reliefs as R          # noqa: E402

CONTRACT = "P2 v3"
SERIES_ALL = ("grid", "sweep", "relax", "separation", "eroded", "envelope", "envelope_real")
SERIES_ENUM = {"grid": pb.GRID, "sweep": pb.SWEEP, "relax": pb.RELAX, "separation": pb.SEPARATION, "eroded": pb.ERODED,
               "envelope": pb.ENVELOPE, "envelope_real": pb.ENVELOPE_REAL}
SHAPE_ENUM = {"hill": pb.HILL, "ridge": pb.RIDGE, "step_up": pb.STEP_UP, "step_down": pb.STEP_DOWN}

# --- постоянные плана (план §2)
H_M, BASE_M, LENGTH_M = 500.0, 1000.0, 20000.0
N_BV = 0.01                        # с⁻¹ над z_i
# Место: центр Алтая как у корпуса hg/ model_place (configs/locations/ongudai.json: 50,79° с. ш., 86,13° в. д., UTC+7),
# 15 июля (weather.CFG reference_context), полдень. Погода/солнце в опыте не используются: N, z_i, H — override.
CTX = dict(lat=50.79, lon=86.13, month=7, day=15, hour_local=12.0, utc_offset=7.0)
# Профиль притока: нейтральный класс D (wind_prof.for_hour на полдень 15 июля при U10 = 5 м/с под сплошной облачностью:
# alpha 0,24, max_profile 2,341) — постоянные плана; значения S2 hg: alpha медиана 0,24, max_profile 0,9–2,9.
ALPHA, MAX_PROFILE = 0.24, 2.341
S_GRID = (0.15, 0.3, 0.5)
HEATS = (0.0, 100.0, 250.0)        # Вт/м²
H_OVER_ZI = (0.3, 1.0, 3.0)
WDIR = 270.0
# --- Numerics по умолчанию решателя (air3d: Params.k_fa = 1 м²/с; solver.solve / air3d/common.py TOL; airlite_gen: late 500/50)
NUM_DEF = dict(envelope_angle_deg=0.0, envelope_wall=pb.WALL_NONE, envelope_z0_m=0.0, dx_m=400.0, advection_order=1, omega_u=1.0, omega_k=1.0, k_floor_m2s=1.0, criterion=pb.ABSOLUTE,
               tol=2e-5, max_outer=1000, snap_from=100, snap_step=50, late_from=500, late_step=50)
# ABSOLUTE tol = tol_mom (м/с², СКО невязки импульса, air3d/common.py TOL); tol_th = 5e-7 К/с и tol_div = 1e-6 1/с
# остаются при нём (решатель берёт их фиксированными; P4 масштабирует вместе с tol).
# RELATIVE: невязка импульса / (U_sat²/a) с a = h = 500 м (характерный масштаб, тот же, что в Fr) — порог равен
# абсолютному при U_sat = 5 м/с: 2e-5·500/25 = 4e-4.
TOL_REL = NUM_DEF["tol"] * H_M / 5.0 ** 2
K_FLOOR_MIN = 10.0                 # м²/с: σ_w·l ≈ 0,3 м/с · 33 м (гипотеза N1)

SEP_S = tuple(round(0.15 + 0.05 * i, 2) for i in range(10))   # 0,15 … 0,60
SEP_FR = (0.3, 0.5, 1.0, 2.0, 3.0, 5.0)
FR_SEP = 3.0
ERODED_N = 6
ENV_ANGLES = (8.0, 12.0, 18.0)
ENV_WALLS = (("ground", pb.WALL_GROUND, 0.0), ("lowz0", pb.WALL_LOW_Z0, 0.001))   # z0 верха огибающей, м (WALL_LOW_Z0)
REAL_RELIEFS = "real/hg_v2"
REAL_CONDITIONS = "conditions/hg_v2_hgw24"
REAL_SOLVE = "solve/hg_v2__hgw24__s0-939a467"   # SY-12: таблица cases, status_h — решение с нагревом
REAL_FR_MIN, REAL_SLOPE_MIN = 1.5, 35.0        # froude таблицы > 1,5, уклон p95 (100 м) ≥ 35°
REAL_N_LOWFR, REAL_N_CONV = 60, 20
ERODED_RELIEF_RANGE = (400.0, 1200.0)   # м: перепад как у идеальных (h = 500); при Fr = 5 U_sat = 5·N·h ≤ 60 м/с


def u10_from_fr(fr, h_m=H_M, n_bv=N_BV, max_profile=MAX_PROFILE):
    """U10 = Fr·N·h / max_profile (м/с)."""
    return fr * n_bv * h_m / max_profile


def fr_from_u10(u10, h_m=H_M, n_bv=N_BV, max_profile=MAX_PROFILE):
    return u10 * max_profile / (n_bv * h_m)


def fr_points():
    """20 логарифмических точек 0,1…5 ∪ шаг 0,05 на 0,3–0,6 и 0,8–1,3; точка лог-ряда отбрасывается, если ближе 8 %
    (относительно) к точке шага — «без повторов»: 30 точек."""
    log = np.logspace(np.log10(0.1), np.log10(5.0), 20)
    step = np.round(np.concatenate([np.arange(0.3, 0.6 + 1e-9, 0.05), np.arange(0.8, 1.3 + 1e-9, 0.05)]), 2)
    keep = [x for x in log if np.min(np.abs(step - x) / x) > 0.08]
    return np.array(sorted(set(np.round(np.concatenate([keep, step]), 4).tolist())))


def sweep_points(fr):
    return fr[(fr >= 0.3 - 1e-9) & (fr <= 1.3 + 1e-9)]


def relax_points():
    """Граничные точки: Fr 0,2–0,5 шаг 0,05 (7) ∪ U10 1,5–3 м/с (5 точек, Fr = U10·max_profile/(N h))."""
    a = np.round(np.arange(0.2, 0.5 + 1e-9, 0.05), 4)
    b = np.round([fr_from_u10(u) for u in np.linspace(1.5, 3.0, 5)], 4)
    return np.array(sorted(set(a.tolist() + b.tolist())))


# --------------------------------------------------------------------------- рельефы идеальные: список и id
def ideal_specs():
    """Все идеальные рельефы плана: (shape, s) в порядке hill, ridge, step_up, step_down × s. id = номер в списке."""
    sp = set()
    for sh in ("hill", "ridge", "step_up"):
        for s in S_GRID:
            sp.add((sh, s))
    for sh in ("ridge", "hill", "step_down"):
        for s in SEP_S:
            sp.add((sh, s))
    order = {k: i for i, k in enumerate(("hill", "ridge", "step_up", "step_down"))}
    return sorted(sp, key=lambda t: (order[t[0]], t[1]))


def data_root():
    return os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data"))


def git_commit():
    try:
        return subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        return ""


def write_ideal_corpus(out=None, force=False):
    """Корпус S1 ideal_v1 (все идеальные рельефы); существует и полон — не трогает (force — перезапись)."""
    import corpus_io as cio
    out = out or os.path.join(data_root(), "corpus", "ideal_v1")
    specs = ideal_specs()
    if os.path.exists(os.path.join(out, "corpus.h5")) and not force:
        c = cio.Corpus(out)
        ok = len(c) == len(specs)
        c.close()
        if ok:
            return out
    rel = []
    for (name, g100, g400, _), (sh, s) in zip(R.load_ideal(specs, H_M, BASE_M), specs):
        rel.append(dict(z100=g100, place=dict(name=name, lat_deg=0.0, lon_deg=0.0, system="ideal", part="", stratum=sh,
                                              source="ideal-v1", zoom=0, src_spacing_m=100.0,
                                              source_sha256=hashlib.sha256(g100.tobytes()).hexdigest())))
    cio.write_reliefs(out, rel, shard_size=100, generator_version="ideal-v1", command="plan_build.py", git_commit=git_commit(),
                      extra_attrs=dict(h_m=H_M, base_m=BASE_M, length_m=LENGTH_M))
    return out


# --------------------------------------------------------------------------- ERODED: выбор 6 рельефов fs1_10k
def pick_eroded(corpus_dir, n_ideal, n=ERODED_N):
    """Детерминированный выбор n = 6 рельефов: среди id ≥ n_ideal (чтобы relief_id не пересекались с ideal_v1) с перепадом
    relief_m 400–1200 м —
    3 терциля по relief_m (перепад) × 2 половины по крутизне p95 (slope_p95_deg_100) внутри терциля; из каждой из 6 ячеек
    берётся рельеф, ближайший к медиане ячейки в нормированных (log10 relief_m, p95) (шкала — СКО по кандидатам), при
    равенстве — меньший id. Возвращает [dict(id, relief_m, slope_p95_deg_100, cell)]."""
    import corpus_io as cio
    c = cio.Corpus(corpus_dir)
    ids = [i for i in c.ids() if i >= n_ideal]
    rm = np.array([c.summary(i)["relief_m"] for i in ids])
    sp = np.array([c.summary(i)["slope_p95_deg_100"] for i in ids])
    ok = (rm >= ERODED_RELIEF_RANGE[0]) & (rm <= ERODED_RELIEF_RANGE[1])
    ids, rm, sp = [i for i, k in zip(ids, ok) if k], rm[ok], sp[ok]
    c.close()
    lr = np.log10(np.maximum(rm, 1.0))
    sl, ss = lr.std() or 1.0, sp.std() or 1.0
    q = np.quantile(lr, [1 / 3, 2 / 3])
    terc = np.searchsorted(q, lr, side="right")
    out = []
    for t in range(3):
        m = terc == t
        half = (sp > np.median(sp[m])).astype(int)
        for hh in range(2):
            cell = m & (half == hh)
            idx = np.nonzero(cell)[0]
            ctr = (np.median(lr[idx]), np.median(sp[idx]))
            d = ((lr[idx] - ctr[0]) / sl) ** 2 + ((sp[idx] - ctr[1]) / ss) ** 2
            k = idx[int(np.lexsort((np.array(ids)[idx], d))[0])]
            out.append(dict(id=int(ids[k]), relief_m=float(rm[k]), slope_p95_deg_100=float(sp[k]), cell=f"relief_tercile{t}_slope{'hi' if hh else 'lo'}"))
    return out[:n]


# --------------------------------------------------------------------------- план
def pick_real(solve_dir=None, relief_corpus=REAL_RELIEFS, conditions=REAL_CONDITIONS, n_low=REAL_N_LOWFR, n_conv=REAL_N_CONV):
    """ENVELOPE_REAL (P2 v3): случаи SY-12 (таблица cases) с slope_p95_deg_100 ≥ 35°.
    (а) froude таблицы > 1,5: все несошедшиеся «h» (status_h = 1; heat_flux_wm2 = −1, variant nonconv_h) и все несошедшиеся
        «m» (status_m = 1; heat_flux_wm2 = 0, nonconv_m); сошедшийся не в обоих — по группе на каждое решение;
    (б) froude ≤ 1,5: n_low = 60 несошедшихся «h» равноотстоящих (linspace по индексу) в порядке (froude, relief_id, cond_id),
        variant nonconv_lowfr;
    (в) контроль: n_conv = 20 случаев froude > 1,5, сошедшихся в обоих решениях (оба ok), решение «h», variant conv —
        равноотстоящие в порядке (slope_p95, relief_id, cond_id).
    → ([dict(relief_id, cond_id, froude, wind_from_deg, slope_p95, heat, variant)], dict со счётчиками)."""
    import glob
    import h5py
    import corpus_io as cio
    root = data_root()
    sd = os.path.join(root, solve_dir or REAL_SOLVE)
    cs = np.concatenate([h5py.File(f, "r")["cases"][:] for f in sorted(glob.glob(os.path.join(sd, "part-*.h5")))])
    tab = cio.Conditions(os.path.join(root, conditions)).table
    key = {(int(a), int(b)): i for i, (a, b) in enumerate(zip(tab["relief_id"], tab["cond_id"]))}
    cr = cio.Corpus(os.path.join(root, relief_corpus))
    sl = {i: float(cr.summary(i)["slope_p95_deg_100"]) for i in cr.ids()}
    cr.close()
    rows = []
    for r in cs:
        k = key[(int(r["relief_id"]), int(r["cond_id"]))]
        s = sl[int(r["relief_id"])]
        if s >= REAL_SLOPE_MIN:
            rows.append(dict(relief_id=int(r["relief_id"]), cond_id=int(r["cond_id"]), froude=float(tab["froude"][k]),
                             wind_from_deg=float(tab["wind_from_deg"][k]), slope_p95=s, sh=int(r["status_h"]), sm=int(r["status_m"])))

    def spread(lst, n):
        if len(lst) <= n:
            return lst
        return [lst[i] for i in np.unique(np.round(np.linspace(0, len(lst) - 1, n)).astype(int))]

    def pick(rs, heat, variant):
        return [dict(r, heat=heat, variant=variant) for r in rs]
    hi = [r for r in rows if r["froude"] > REAL_FR_MIN]
    lo = sorted([r for r in rows if r["froude"] <= REAL_FR_MIN and r["sh"] != 0], key=lambda r: (r["froude"], r["relief_id"], r["cond_id"]))
    ctrl = sorted([r for r in hi if r["sh"] == 0 and r["sm"] == 0], key=lambda r: (r["slope_p95"], r["relief_id"], r["cond_id"]))
    sel = (pick([r for r in hi if r["sh"] != 0], -1.0, "nonconv_h") + pick([r for r in hi if r["sm"] != 0], 0.0, "nonconv_m")
           + pick(spread(lo, n_low), -1.0, "nonconv_lowfr") + pick(spread(ctrl, n_conv), -1.0, "conv"))
    info = dict(candidates_slope35=len(rows), hi_fr=len(hi), nonconv_h_hi=sum(r["variant"] == "nonconv_h" for r in sel),
                nonconv_m_hi=sum(r["variant"] == "nonconv_m" for r in sel), nonconv_h_lowfr_found=len(lo),
                nonconv_lowfr=sum(r["variant"] == "nonconv_lowfr" for r in sel), conv_found=len(ctrl),
                conv=sum(r["variant"] == "conv" for r in sel))
    return sel, info


def _numerics(msg, **kw):
    d = dict(NUM_DEF)
    d.update(kw)
    for k, v in d.items():
        setattr(msg, k, v)


def build_plan(name="ap_v1", out=None, series=SERIES_ALL, corpus_out=None, eroded_corpus="corpus/fs1_10k", write=True, quiet=False):
    """Строит Plan (protobuf); write — пишет plan.pb/plan.json в `<out>/<name>/` и корпус ideal_v1. → (plan, table)."""
    series = [s.strip() for s in (series.split(",") if isinstance(series, str) else series) if s.strip()]
    bad = [s for s in series if s not in SERIES_ALL]
    if bad:
        raise ValueError(f"неизвестные серии {bad}; допустимо {SERIES_ALL}")
    out = out or os.path.join(data_root(), "phase")
    plan = pb.Plan(contract=CONTRACT, name=name, created=datetime.datetime.now().isoformat(timespec="seconds"),
                   git_commit=git_commit(), command=" ".join(["plan_build.py"] + sys.argv[1:]))
    c = plan.context
    c.lat, c.lon, c.month, c.day, c.hour_local, c.utc_offset = CTX["lat"], CTX["lon"], CTX["month"], CTX["day"], CTX["hour_local"], CTX["utc_offset"]
    c.alpha, c.max_profile, c.base_m, c.h_m = ALPHA, MAX_PROFILE, BASE_M, H_M

    specs = ideal_specs()
    rid = {sp: i for i, sp in enumerate(specs)}
    for (sh, s), i in ((sp, rid[sp]) for sp in specs):
        r = plan.reliefs.add()
        r.relief_id, r.corpus_relief_id, r.name, r.shape, r.slope, r.h_m = i, i, R.ideal_name(sh, s, LENGTH_M), SHAPE_ENUM[sh], s, H_M
        r.a_m = float(R.ideal_scale_a(sh, s, H_M))
        r.length_m = LENGTH_M if sh == "ridge" else 0.0
        r.corpus = "corpus/ideal_v1"

    fr_all = fr_points()
    state = dict(next_line=0, next_case=0)
    lines_by_cfg = {}   # (shape, s, H, hz, wdir) -> line_id GRID

    def add_line(ser, relief_id, H, hz, wdir, fr, start, direction=pb.DIR_NONE, ref=-1, variant="", cond="", cid=-1, **num):
        ln = plan.lines.add()
        ln.line_id, ln.series, ln.relief_id = state["next_line"], SERIES_ENUM[ser], relief_id
        ln.heat_flux_wm2, ln.h_over_zi, ln.n_bv_s, ln.wdir_from_deg = H, hz, N_BV, wdir
        _numerics(ln.numerics, **num)
        ln.conditions, ln.cond_id = cond, cid
        ln.start, ln.direction, ln.ref_line_id, ln.variant = start, direction, ref, variant
        ln.fr_f64 = np.asarray(fr, dtype="<f8").tobytes()
        ln.first_case_id = state["next_case"]
        state["next_line"] += 1
        state["next_case"] += len(fr)
        return ln

    grid_shapes = ("hill", "ridge", "step_up")
    cfgs = [(sh, s, H, hz) for sh in grid_shapes for s in S_GRID for H in HEATS for hz in H_OVER_ZI]
    # ref_line_id ссылается на GRID только если серия grid выбрана (иначе −1); нумерация сквозная по выбранным сериям.
    grid_ids = {}
    if "grid" in series:
        for sh, s, H, hz in cfgs:
            ln = add_line("grid", rid[(sh, s)], H, hz, WDIR, fr_all, pb.COLD)
            grid_ids[(sh, s, H, hz, WDIR)] = ln.line_id
    if "sweep" in series:
        sw = sweep_points(fr_all)
        for sh, s, H, hz in cfgs:
            ref = grid_ids.get((sh, s, H, hz, WDIR), -1)
            add_line("sweep", rid[(sh, s)], H, hz, WDIR, sw, pb.WARM_PREV, pb.UP, ref, "up")
            add_line("sweep", rid[(sh, s)], H, hz, WDIR, sw[::-1], pb.WARM_PREV, pb.DOWN, ref, "down")
    if "relax" in series:
        rp = relax_points()
        calm = np.array([0.1, 0.15, 0.2])
        variants = (("omega", dict(omega_u=0.5, omega_k=0.5)), ("kfloor", dict(k_floor_m2s=K_FLOOR_MIN)),
                    ("rel", dict(criterion=pb.RELATIVE, tol=TOL_REL)))
        for sh in grid_shapes:
            for H in HEATS:
                for hz in H_OVER_ZI:
                    ref = grid_ids.get((sh, 0.3, H, hz, WDIR), -1)
                    for v, kw in variants:
                        add_line("relax", rid[(sh, 0.3)], H, hz, WDIR, rp, pb.COLD, ref=ref, variant=v, **kw)
                    add_line("relax", rid[(sh, 0.3)], H, hz, WDIR, calm, pb.COLD, ref=ref, variant="calm",
                             criterion=pb.RELATIVE, tol=TOL_REL)
    def sep_configs():
        """50 конфигураций SEPARATION: (shape, s, fr-точки, H, wdir, variant)."""
        for sh in ("ridge", "hill", "step_down"):
            for s in SEP_S:
                yield sh, s, [FR_SEP], 0.0, WDIR, "slope"
        for s in (0.3, 0.5):
            yield "ridge", s, list(SEP_FR), 0.0, WDIR, "fr"
        for H in (100.0, 250.0):
            for s in (0.3, 0.5):
                yield "ridge", s, [FR_SEP], H, WDIR, "heat"
        for wd in (300.0, 330.0):
            for s in (0.3, 0.5):
                yield "ridge", s, [FR_SEP], 0.0, wd, "oblique"

    sep100 = {}   # конфигурация -> line_id окна 100 м (эталон ENVELOPE)
    if "separation" in series:
        for dx, order in ((100.0, 2), (400.0, 1)):
            for sh, s, fr, H, wdir, variant in sep_configs():
                ref = grid_ids.get((sh, s, H, 0.3, wdir), -1) if dx == 400.0 else -1
                ln = add_line("separation", rid[(sh, s)], H, 0.3, wdir, fr, pb.COLD, ref=ref, variant=variant, dx_m=dx,
                              advection_order=order)
                if dx == 100.0:
                    sep100[(sh, s, tuple(fr), H, wdir, variant)] = ln.line_id
    eroded_info = []
    if "eroded" in series:
        ed = os.path.join(data_root(), eroded_corpus)
        picked = pick_eroded(ed, len(specs))
        for p in picked:
            r = plan.reliefs.add()
            pid = len(plan.reliefs) - 1
            r.relief_id, r.corpus_relief_id, r.name, r.shape, r.slope, r.h_m, r.a_m, r.length_m, r.corpus = (
                pid, p["id"], f"{os.path.basename(eroded_corpus)}_{p['id']:05d}", pb.CORPUS, float(np.tan(np.radians(p["slope_p95_deg_100"]))),
                p["relief_m"], 0.0, 0.0, eroded_corpus)
            p["plan_relief_id"] = pid
        for p in picked:
            add_line("eroded", p["plan_relief_id"], 0.0, 1.0, WDIR, fr_all, pb.COLD)
        eroded_info = picked
    if "envelope" in series:
        for sh, s, fr, H, wdir, variant in sep_configs():
            ref = sep100.get((sh, s, tuple(fr), H, wdir, variant), -1)
            for ang in ENV_ANGLES:
                for wn, wall, z0 in ENV_WALLS:
                    add_line("envelope", rid[(sh, s)], H, 0.3, wdir, fr, pb.COLD, ref=ref, variant=variant,
                             envelope_angle_deg=ang, envelope_wall=wall, envelope_z0_m=z0)
    real_info = {}
    if "envelope_real" in series:
        cases, real_info = pick_real()
        import corpus_io as cio
        cr = cio.Corpus(os.path.join(data_root(), REAL_RELIEFS))
        pid_of = {}
        for p in cases:
            if p["relief_id"] not in pid_of:
                sm = cr.summary(p["relief_id"])
                r = plan.reliefs.add()
                pid_of[p["relief_id"]] = len(plan.reliefs) - 1
                r.relief_id, r.corpus_relief_id, r.name, r.shape = pid_of[p["relief_id"]], p["relief_id"], cr.place(p["relief_id"])["name"], pb.CORPUS
                r.slope, r.h_m, r.a_m, r.length_m, r.corpus = float(np.tan(np.radians(sm["slope_p95_deg_100"]))), float(sm["relief_m"]), 0.0, 0.0, REAL_RELIEFS
        cr.close()
        for p in cases:
            kw = dict(cond=REAL_CONDITIONS, cid=p["cond_id"], variant=p["variant"])
            base = add_line("envelope_real", pid_of[p["relief_id"]], p["heat"], 0.0, p["wind_from_deg"], [p["froude"]], pb.COLD, **kw)
            for ang in ENV_ANGLES:
                for wn, wall, z0 in ENV_WALLS:
                    add_line("envelope_real", pid_of[p["relief_id"]], p["heat"], 0.0, p["wind_from_deg"], [p["froude"]], pb.COLD,
                             ref=base.line_id, envelope_angle_deg=ang, envelope_wall=wall, envelope_z0_m=z0, **kw)
        real_info["selected"] = cases
        eroded_info = list(eroded_info)
    plan.n_cases = state["next_case"]

    table = {}
    for ln in plan.lines:
        n = len(ln.fr_f64) // 8
        t = table.setdefault(pb.Series.Name(ln.series), [0, 0])
        t[0] += 1
        t[1] += n
    if write:
        d = Path(out) / name
        d.mkdir(parents=True, exist_ok=True)
        write_ideal_corpus(corpus_out)
        for fn, data, mode in (("plan.pb", plan.SerializeToString(), "wb"),):
            tmp = d / (fn + ".tmp")
            tmp.write_bytes(data)
            os.replace(tmp, d / fn)
        tmp = d / "plan.json.tmp"
        tmp.write_text(json.dumps(plan_to_json(plan, eroded_info, real_info), ensure_ascii=False, indent=1))
        os.replace(tmp, d / "plan.json")
    if not quiet:
        print(f"план {name}: линий {len(plan.lines)}, случаев {plan.n_cases}")
        for s, (nl, nc) in table.items():
            print(f"  {s:<11} линий {nl:>4}  случаев {nc:>5}")
    return plan, table


def plan_to_json(plan, eroded_info=(), real_info=None):
    from google.protobuf import json_format
    d = json_format.MessageToDict(plan, preserving_proto_field_name=True, always_print_fields_with_no_presence=True)
    for ln, m in zip(d["lines"], plan.lines):
        ln["fr"] = np.frombuffer(m.fr_f64, dtype="<f8").tolist()
        ln.pop("fr_f64", None)
    if eroded_info:
        d["eroded_selection"] = list(eroded_info)
    if real_info:
        d["envelope_real_selection"] = real_info
    return d


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--name", default="ap_v1")
    ap.add_argument("--out", default=os.path.join(data_root(), "phase"))
    ap.add_argument("--series", default=",".join(SERIES_ALL))
    ap.add_argument("--corpus-out", default=None, help="каталог корпуса ideal_v1 (по умолчанию $AIR_SYNTH_DATA/corpus/ideal_v1)")
    a = ap.parse_args(argv)
    build_plan(a.name, os.path.expanduser(a.out), a.series, a.corpus_out)


if __name__ == "__main__":
    main()
