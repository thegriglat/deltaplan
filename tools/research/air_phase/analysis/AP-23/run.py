"""AP-23 (P15): проверка классификатора фаз — эталон `classifier_ref.py` (входы игры) против фаз по параметрам порядка
решений Пикара. Только CPU, данные только читаются, решения не пересчитываются.

    PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
    $PY tools/research/air_phase/analysis/AP-23/run.py [--stage prep|report|all] [--workers 8]

Стадии: prep — классификатор по случаям (идеальные ap_v1/ap_v2 после пересчёта AP-14, ap_v3, SY-12 7320 случаев, ERODED)
и поклеточные счёты на сошедшихся полях (кэш в out/AP-23/, ≈ 10 мин на 8 процессах); report — матрицы, подбор порогов,
summary.json, section.md, fig_*.png.
"""
from __future__ import annotations

import argparse, glob, json, math, os, sys, time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import h5py
import numpy as np
from scipy import ndimage

HERE = Path(__file__).resolve().parent
AP = HERE.parents[1]
sys.path.insert(0, str(AP))
import classifier_ref as CR  # noqa: E402
from assembly import mechanisms as M  # noqa: E402

DATA = Path(os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data")))
PH = DATA / "phase"
SY = DATA / "solve" / "hg_v2__hgw24__s0-939a467"
SYC = DATA / "conditions" / "hg_v2_hgw24"
OUT = AP / "out" / "AP-23"
EDGE = 5
NEAR_SPREAD = 0.05          # м/с: «почти сошлось» (phase_stats.py)
HARD_SPREAD_REL = 0.1       # доля U_sat: блуждание, которое ω не лечит (AP-9: 0,39–0,63 U_sat в штиле, 0,07 после ω)
C_WMS = 1.0                 # м/с: волна, которую видит слой (min_sink дельтаплана ≈ 1 м/с)
B_AREA_KM2 = 4.0            # км²: минимальная площадь подветренной зоны, которую видит слой (AP-8 MIN_DY)
SHELTER_R_M = 2000.0        # клетка в тени: гребень против ветра в пределах 2 км
SHELTER_DH_M = 50.0         # … выше клетки на 50 м
AGL = M.AGL_M
K25, K600 = 0, int(np.where(AGL == 600)[0][0])
SER_GRID, SER_ERODED = 1, 5

# Варианты для поклеточных счётов и ERODED: (имя, переопределения конфига)
CELL_VARIANTS = [
    ("ap18", {}),
    ("ap18_C", {"c_w_ms": C_WMS}),
    ("dloc100_C", {"c_w_ms": C_WMS, "d_local": True, "d_local_ramp_m": 100.0}),
]
ERO_VARIANTS = []
for bd in (50.0, 100.0, 200.0):
    for sm in (0.0, 1.0, 1.5, 2.0, 3.0):
        for dl in (0.0, 50.0, 100.0, 200.0):
            ERO_VARIANTS.append((f"b{int(bd)}_s{sm:g}_d{int(dl)}",
                                 {"b_depth_m": bd, "smooth_cells": sm, "d_local": dl > 0, "d_local_ramp_m": max(dl, 1.0)}))


# ------------------------------------------------------------------ truth по клеткам
def inflow(u10, alpha, mp, z):
    z_sat = 10.0 * mp ** (1.0 / alpha)
    return u10 * min((max(z, 0.1) / z_sat) ** alpha, 1.0)


def sheltered(hc, wdir):
    """Клетка в тени: максимум рельефа против ветра на 400…2000 м выше клетки на SHELTER_DH_M (независимо от огибающей)."""
    e = M.wind_unit(wdir)
    ny, nx = hc.shape
    J, I = np.indices(hc.shape).astype(float)
    best = np.full(hc.shape, -np.inf)
    for d in np.arange(M.DX, SHELTER_R_M + 1, M.DX):
        fi = np.clip(I - e[0] * d / M.DX, 0, nx - 1)
        fj = np.clip(J - e[1] * d / M.DX, 0, ny - 1)
        best = np.maximum(best, ndimage.map_coordinates(hc, [fj, fi], order=1, mode="nearest"))
    return best - hc >= SHELTER_DH_M


def cell_truth(u25, v25, w600, hc, wdir, u10, alpha, mp):
    """Местная фаза по параметрам порядка поля (определения — phase_stats.field_features, по клеткам):
    обратное течение rev: u·e < −0,05·max(U_b, 0,3); застой stag: |u_h| < 0,3 U_b; обход turn: поворот > 45° при
    |u_h| > 0,2 U_b (U_b — приток на 25 м). B = rev в тени гребня (гребень против ветра ≤ 2 км выше клетки на 50 м);
    D = (stag | turn | rev) вне B; C = |w(600 м)| ≥ 1 м/с вне B, D; иначе A. → (ny, nx) int: A 0, B 1, C 2, D 3."""
    e = M.wind_unit(wdir)
    ub = inflow(u10, alpha, mp, 25.0)
    along = u25 * e[0] + v25 * e[1]
    sp = np.hypot(u25, v25)
    rev = along < -0.05 * max(ub, 0.3)
    stag = sp < 0.3 * ub
    turn = (along / np.maximum(sp, 1e-3) < math.cos(math.radians(45))) & (sp > 0.2 * ub)
    sh = sheltered(hc, wdir)
    B = rev & sh
    D = (stag | turn | rev) & ~B
    C = (np.abs(w600) >= C_WMS) & ~B & ~D
    lab = np.zeros(hc.shape, np.int8)
    lab[C] = 2
    lab[D] = 3
    lab[B] = 1
    return lab


def cls_label(W, full):
    """Местная фаза классификатора среди фаз Пикара A, B, C, D (argmax); 4 — вся область механизмам."""
    if full:
        return np.full(W.shape[1:], 4, np.int8)
    return np.argmax(W[[CR.PI[p] for p in CR.PICARD]], axis=0).astype(np.int8)


def speck_metrics(lab, min_cells=4):
    """«Шахматка»: доля клеток со сменой главной фазы хотя бы у одного из 4 соседей (граница), доля клеток в
    связных областях (4-связность) площадью < min_cells (пятна), число областей."""
    l = lab[EDGE:-EDGE, EDGE:-EDGE]
    diff = np.zeros(l.shape, bool)
    diff[1:] |= l[1:] != l[:-1]; diff[:-1] |= l[1:] != l[:-1]
    diff[:, 1:] |= l[:, 1:] != l[:, :-1]; diff[:, :-1] |= l[:, 1:] != l[:, :-1]
    n_reg, speck = 0, 0
    for v in np.unique(l):
        cc, n = ndimage.label(l == v)
        if n:
            sz = np.bincount(cc.ravel())[1:]
            n_reg += n
            speck += int(sz[sz < min_cells].sum())
    return float(diff.mean()), float(speck / l.size), int(n_reg)


# ------------------------------------------------------------------ SY-12
def _sy_cond_table():
    rows = {}
    for p in sorted(SYC.glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            t = h["conditions/table"][:]
        for r in t:
            rows[(int(r["relief_id"]), int(r["cond_id"]))] = {n: r[n].item() for n in t.dtype.names}
    return rows


_COND = None


def sy_part(path):
    """Один файл S5: классификатор (AP-18) по случаям m и h; на сошедшихся «m» — местные фазы (варианты CELL_VARIANTS)."""
    global _COND
    if _COND is None:
        _COND = _sy_cond_table()
    from hybrid import drainage as DR
    out_cases, conf = [], {v: np.zeros((4, 5), np.int64) for v, _ in CELL_VARIANTS}
    with h5py.File(path, "r") as h:
        cases = h["cases"][:]
        for i, c in enumerate(cases):
            cond = dict(_COND[(int(c["relief_id"]), int(c["cond_id"]))])
            hc = h["inputs/hc"][i].astype(np.float64)
            heat = h["inputs/heat_flux"][i].astype(np.float64)
            dep = CR.envelope_depth(hc, cond, CR.CONFIG_AP18)
            dr = DR.evening_drainage(hc, heat, cond)
            rm = CR.classify(hc, cond, None, "m", None, env_depth=dep)
            rh = CR.classify(hc, cond, heat, "h", None, env_depth=dep, drainage=dr)
            rC = CR.classify(hc, cond, None, "m", {"c_w_ms": C_WMS}, env_depth=dep)
            im, ih = rm["info"], rh["info"]
            rec = dict(case=int(c["case"]), status_m=int(c["status_m"]), status_h=int(c["status_h"]),
                       spread_m=float(c["late_spread60_p90_m"]), spread_h=float(c["late_spread60_p90_h"]),
                       iters_m=int(c["iters_m"]), iters_h=int(c["iters_h"]),
                       sun_el=float(cond["sun_el_deg"]), hs=float(cond["hs_w_m2"]), wstar_over_u=float(cond["w_star_over_u"]),
                       f_frac=ih["f_frac"], g_frac=ih["g_frac"], g_active=bool(dr["diag"]["active"]),
                       b_frac_m=im["b_frac"], b_frac_h=ih["b_frac"], wF_mean=ih["mean"]["F"], wG_mean=ih["mean"]["G"],
                       dloc_frac=float(np.mean(hc < im["Hc"])), c_frac=rC["info"]["c_frac"])
            for k in ("fr", "u10", "usat", "nbv", "u_over_n", "s95", "Hc", "base", "relief"):
                rec[k] = im[k]
            fm = None
            if int(c["status_m"]) == 0:
                fm = h["fields/m"][i]
                tr = cell_truth(fm[0, K25].astype(np.float64), fm[1, K25].astype(np.float64), fm[2, K600].astype(np.float64),
                                hc, cond["wind_from_deg"], cond["u10_m_s"], cond["alpha"], cond["max_profile"])
                trc = tr[EDGE:-EDGE, EDGE:-EDGE].ravel()
                cnt = np.bincount(trc, minlength=4)
                rec.update({f"tr_{p}": int(cnt[j]) for j, p in enumerate(CR.PICARD)})
                for v, ov in CELL_VARIANTS:
                    r = rm if not ov else rC if ov == {"c_w_ms": C_WMS} else CR.classify(hc, cond, None, "m", ov, env_depth=dep)
                    lab = cls_label(r["weights"], r["info"]["full"])[EDGE:-EDGE, EDGE:-EDGE].ravel()
                    np.add.at(conf[v], (trc, lab), 1)
            out_cases.append(rec)
    return out_cases, conf


# ------------------------------------------------------------------ идеальные формы
def _part_index(res_dir):
    idx = {}
    for p in sorted(Path(res_dir).glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            for j, cid in enumerate(h["cases"]["case_id"][:]):
                idx[int(cid)] = (str(p), j)
    return idx


def ideal_cases(job):
    """job: (список строк dict с cond и где лежит hc), → записи классификатора (AP-18, m и h) + B-доля, F-доля."""
    recs = []
    for r in job:
        with h5py.File(r["path"], "r") as h:
            hc = h["inputs/hc"][r["j"]].astype(np.float64)
            heat = h["inputs/heat_flux"][r["j"]].astype(np.float64)
        cond = r["cond"]
        base = float(np.percentile(hc, 5))
        cond["z_i_m"] = base + cond.pop("z_i_agl_m")
        dep = CR.envelope_depth(hc, cond, CR.CONFIG_AP18)
        rm = CR.classify(hc, cond, None, "m", None, env_depth=dep)
        rh = CR.classify(hc, cond, heat, "h", None, env_depth=dep) if np.any(heat > 0) else rm
        rC = CR.classify(hc, cond, None, "m", {"c_w_ms": C_WMS}, env_depth=dep)
        im, ih = rm["info"], rh["info"]
        rec = dict(key=r["key"], c_frac=rC["info"]["c_frac"], f_frac=ih["f_frac"], b_frac_m=im["b_frac"], b_frac_h=ih["b_frac"],
                   b_area_km2=float(ih["b_frac"] * 96 * 96 * 0.16), wF_mean=ih["mean"]["F"])
        for k in ("fr", "u10", "usat", "nbv", "u_over_n", "s95", "Hc", "base", "relief"):
            rec[k] = im[k]
        recs.append(rec)
    return recs


def eroded_case(r):
    """ERODED: местные фазы истины (если сошёлся) и классификатора по вариантам ERO_VARIANTS; метрики «шахматки»."""
    with h5py.File(r["path"], "r") as h:
        hc = h["inputs/hc"][r["j"]].astype(np.float64)
        f = h["fields/f"][r["j"]] if r["status"] == 0 else None
    cond = r["cond"]
    cond["z_i_m"] = float(np.percentile(hc, 5)) + cond.pop("z_i_agl_m")
    tr = None
    if f is not None:
        tr = cell_truth(f[0, K25].astype(np.float64), f[1, K25].astype(np.float64), f[2, K600].astype(np.float64),
                        hc, cond["wind_from_deg"], cond["u10_m_s"], cond["alpha"], cond["max_profile"])
    deps = {}
    out = dict(key=r["key"], fr=cond["froude"], status=r["status"], variants={})
    if tr is not None:
        out["tr"] = speck_metrics(tr)
    for name, ov in ERO_VARIANTS:
        cfg = dict(ov, c_w_ms=C_WMS)
        bd = ov["b_depth_m"]
        if bd not in deps:
            deps[bd] = CR.envelope_depth(hc, cond, CR.merged(**cfg))
        res = CR.classify(hc, cond, None, "m", cfg, env_depth=deps[bd])
        lab = cls_label(res["weights"], res["info"]["full"])
        v = dict(zip(("bound", "speck", "nreg"), speck_metrics(lab)))
        if tr is not None and not res["info"]["full"]:
            a, b = tr[EDGE:-EDGE, EDGE:-EDGE].ravel(), lab[EDGE:-EDGE, EDGE:-EDGE].ravel()
            v["acc"] = float((a == b).mean())
            v["conf"] = np.bincount(a * 5 + b, minlength=20).reshape(4, 5).tolist()
        out["variants"][name] = v
    return out


def load_ideal_rows():
    """Строки идеальных случаев: ap_v1 после AP-14 (GRID, ERODED), ap_v2 после AP-14, ap_v3 (все варианты)."""
    sys.path.insert(0, str(AP))
    import phase_io as PIO
    rows = []
    for plan_name, feat, res in (("ap_v1", "features_ap_v1_merged.h5", "ap_v1__s1-74644c4"),
                                 ("ap_v2", "features_ap_v2_merged.h5", "ap_v2__s1-74644c4")):
        plan, _, lines, rel, _ = PIO.load_plan(PH / plan_name)
        ctx = plan.context
        idx = _part_index(PH / res)
        with h5py.File(PH / feat, "r") as h:
            t = h["features"][:]
        for r in t:
            if plan_name == "ap_v1" and int(r["series"]) not in (SER_GRID, SER_ERODED):
                continue
            path, j = idx[int(r["case_id"])]
            cond = dict(froude=float(r["fr"]), u10_m_s=float(r["u10"]), u_sat_m_s=float(r["u_sat"]),
                        n_bv_s=float(r["n_bv"]), wind_from_deg=float(r["wdir_from_deg"]), z_i_agl_m=float(r["z_i_agl_m"]),
                        alpha=float(ctx.alpha), max_profile=float(ctx.max_profile), sun_el_deg=90.0,
                        hs_w_m2=float(r["heat_flux_wm2"]), cloud_cover=0.0)
            rows.append(dict(key=f"{plan_name}:{int(r['case_id'])}", path=path, j=j, cond=cond, plan=plan_name,
                             row={n: (r[n].item() if not isinstance(r[n], bytes) else r[n].decode()) for n in
                                  ("case_id", "series", "status", "iters", "late_spread60_p90", "u_sat", "u10", "fr", "n_bv",
                                   "heat_flux_wm2", "f_stag25", "f_turn25", "f_rev25", "f_wmax600", "lee_rev_area25_km2",
                                   "mech_case_id", "h_m", "h_over_zi", "slope", "rr_used", "zi_over_L")}
                             | dict(shape=r["shape"].decode(), variant=r["variant"].decode(), relief_name=r["relief_name"].decode())))
    plan, _, lines, rel, cases = PIO.load_plan(PH / "ap_v3")
    ctx = plan.context
    for p in sorted((PH / "ap_v3__s1-ee7be55").glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            t = h["cases"][:]
            o = h["order"][:]
        for j, (r, oo) in enumerate(zip(t, o)):
            ln = lines[int(r["line_id"])]
            relief = rel[ln.relief_id]
            cond = dict(froude=float(r["fr"]), u10_m_s=float(r["u10"]), u_sat_m_s=float(r["u_sat"]), n_bv_s=float(r["n_bv"]),
                        wind_from_deg=float(r["wdir_from_deg"]), z_i_agl_m=float(r["z_i_agl_m"]), alpha=float(ctx.alpha),
                        max_profile=float(ctx.max_profile), sun_el_deg=90.0, hs_w_m2=float(r["heat_flux_wm2"]), cloud_cover=0.0)
            rows.append(dict(key=f"ap_v3:{int(r['case_id'])}", path=str(p), j=j, cond=cond, plan="ap_v3",
                             row=dict(case_id=int(r["case_id"]), series=int(r["series"]), status=int(r["status"]), iters=int(r["iters"]),
                                      late_spread60_p90=float(r["late_spread60_p90"]), u_sat=float(r["u_sat"]),
                                      u10=float(r["u10"]), fr=float(r["fr"]), n_bv=float(r["n_bv"]),
                                      heat_flux_wm2=float(r["heat_flux_wm2"]), f_stag25=float(oo["f_stag25"]),
                                      f_turn25=float(oo["f_turn25"]), f_rev25=float(oo["f_rev25"]),
                                      f_wmax600=float(oo["f_wmax600"]), lee_rev_area25_km2=np.nan, mech_case_id=-1,
                                      h_m=float(relief.h_m), h_over_zi=float(ln.h_over_zi), slope=np.nan, rr_used=0,
                                      zi_over_L=float(r["zi_over_L"]), shape="RIDGE", variant=ln.variant, relief_name="")))
    return rows


def stage_prep(workers):
    OUT.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    rows = load_ideal_rows()
    json.dump([dict(key=r["key"], plan=r["plan"], **r["row"]) for r in rows], open(OUT / "ideal_rows.json", "w"),
              default=float)
    # ERODED: поля — из исходного ap_v1 (пересчёт AP-14 ERODED не трогал)
    ero = [dict(r, status=int(r["row"]["status"])) for r in rows if r["plan"] == "ap_v1" and r["row"]["series"] == SER_ERODED]
    jobs = [rows[i:i + 40] for i in range(0, len(rows), 40)]
    parts = sorted(SY.glob("part-*.h5"))
    with ProcessPoolExecutor(workers) as ex:
        fi = ex.map(ideal_cases, jobs)
        fe = ex.map(eroded_case, ero)
        fs = ex.map(sy_part, parts)
        ideal = [x for b in fi for x in b]
        json.dump(ideal, open(OUT / "ideal_cls.json", "w"), default=float)
        print(f"ideal {len(ideal)} {time.time() - t0:.0f} s", flush=True)
        eroded = list(fe)
        json.dump(eroded, open(OUT / "eroded.json", "w"), default=float)
        print(f"eroded {len(eroded)} {time.time() - t0:.0f} s", flush=True)
        sy, conf = [], {v: np.zeros((4, 5), np.int64) for v, _ in CELL_VARIANTS}
        for k, (recs, cf) in enumerate(fs):
            sy.extend(recs)
            for v in conf:
                conf[v] += cf[v]
            if k % 10 == 0:
                print(f"sy12 part {k}/{len(parts)} {time.time() - t0:.0f} s", flush=True)
    json.dump(sy, open(OUT / "sy12_cls.json", "w"), default=float)
    json.dump({v: c.tolist() for v, c in conf.items()}, open(OUT / "sy12_cells.json", "w"))
    print(f"prep done {time.time() - t0:.0f} s", flush=True)


# ================================================================== report
AP14_SUMMARY = Path(os.environ.get("AP14_SUMMARY", str(AP / "analysis" / "AP-14" / "summary.json")))
PER_CASE = AP / "out" / "per_case.npz"
RUN_RERUN_DIR = DATA / "phase" / "ap23_rerun"
TRUTH_RULES = {
    "picard_ok": "status 0 или (status 1 и late_spread60_p90 < 0,05 м/с — «почти сошлось», phase_stats.py); для пересчёта AP-14 (2000 итераций) — ещё и не больше 1000 итераций (бюджет Пикара игры, max_outer 1000, AP-18), иначе — блуждание",
    "nonpicard_hard": "status 1 и late_spread60_p90 ≥ 0,1·U_sat — блуждание, которое ω = 0,5 не лечит (AP-9: 0,39–0,63 U_sat в штиле; после ω у Fr 0,5 — 0,07)",
    "uncertain": "status 1 и 0,05 м/с ≤ разброс < 0,1·U_sat — счёт при ω = 1; ω = 0,5 игры, вероятно, сводит (AP-9, AP-14) — вне знаменателей ошибок",
    "F": "решение с нагревом блуждает (hard), а без нагрева (близнец H = 0 / решение «m») — Пикар-ok: несходимость от конвекции",
    "N": "блуждает и без нагрева: H (штиль) или сильное D — по полю не различить, оба — механизмы",
    "D": "Пикар-ok и ≥ 2 из 3: f_stag25 ≥ τs, f_turn25 ≥ τt, f_rev25 ≥ τr (τ — середины сигмоид AP-8 по линиям, y0 + Δy/2, медиана)",
    "A": "Пикар-ok, не D",
    "B_present": "площадь разрешённого обратного течения за гребнем lee_rev_area25_km2 ≥ 4 км² (минимум, который видит слой, AP-8); классификатор — B ≥ 0,5 на ≥ 4 км²",
    "C_present": "max |w| на 600 м ≥ 1 м/с (min_sink дельтаплана); классификатор — C ≥ 0,5 хотя бы в 2 клетках",
    "cells": "по клеткам на 25 м (сошедшиеся поля «m»): rev u·e < −0,05·max(U_b, 0,3), stag |u_h| < 0,3 U_b, turn поворот > 45° при |u_h| > 0,2 U_b; B = rev в тени (гребень против ветра ≤ 2 км выше клетки на 50 м), D = (stag|turn|rev) вне B, C = |w(600 м)| ≥ 1 м/с вне B, D, иначе A; край 5 клеток не считается",
}


def _sigv(x, xc, w):
    x = np.maximum(np.asarray(x, np.float64), 1e-12)
    return 1.0 / (1.0 + np.exp(-(np.log10(x) - math.log10(xc)) / w))


def full_freeze(d, cfg):
    """Векторно: H + Ds ≥ freeze_w (как classifier_ref.case_weights)."""
    xh = d["fr"] if cfg["h_axis"] == "fr" else d["u10"]
    wH = 1.0 - _sigv(xh, cfg["h_c"], cfg["h_w_dec"])
    ax = cfg["d_strong_axis"]
    if ax == "none":
        sS = np.zeros_like(wH)
    else:
        if ax == "nc_law":
            xs = cfg["d_strong_nc0"] * (np.maximum(d["usat"], 1e-3) / 3.0) ** cfg["d_strong_p"] / np.maximum(d["nbv"], 1e-6)
        else:
            xs = d["fr"] if ax == "fr" else d["u_over_n"]
        sS = 1.0 - _sigv(xs, cfg["d_strong_c"], cfg["d_strong_w_dec"])
    wDs = (1 - wH) * sS
    wD = (1 - wH) * (1 - _sigv(d["fr"], cfg["d_fr_c"], cfg["d_w_dec"]))
    return (wH + wDs) >= cfg["freeze_w"], wH, wDs, wD


def omega_v(d, cfg):
    def band(x, lo, hi, w):
        return _sigv(x, lo, w) * (1 - _sigv(x, hi, w))
    b = np.maximum(band(d["fr"], cfg["omega_fr_lo"], cfg["omega_fr_hi"], cfg["omega_w_dec"]),
                   band(d["u10"], cfg["omega_u10_lo"], cfg["omega_u10_hi"], cfg["omega_w_dec"]))
    om = 1 - (1 - cfg["omega_band"]) * b
    return np.where(om > 0.99, 1.0, om)


def conv_label(status, spread, usat):
    """0 — Пикар-ok, 2 — блуждание hard, 1 — неопределённо (см. TRUTH_RULES)."""
    ok = (status == 0) | (spread < NEAR_SPREAD)
    hard = (~ok) & (spread >= HARD_SPREAD_REL * usat)
    return np.where(ok, 0, np.where(hard, 2, 1))


def ap8_levels():
    b = json.load(open(AP / "analysis" / "AP-8" / "summary.json"))["boundaries"]
    lev = {}
    for p in ("f_stag25", "f_turn25", "f_rev25"):
        mids = [r["y0"] + r["dy"] / 2 for r in b if r["param"] == p and r["H"] == 0.0]
        if not mids:
            mids = [r["y0"] + r["dy"] / 2 for r in b if r["param"] == p]
        lev[p] = float(np.median(mids))
    return lev


def errs(truth, mech, frz=None):
    """truth: 0 ok, 2 hard; mech — отдано механизму (bool); frz — доля замороженных клеток (для клеточной ошибки)."""
    np_ = truth == 2
    p_ = truth == 0
    out = dict(n_nonpicard=int(np_.sum()), n_picard=int(p_.sum()),
               nonpicard_to_picard=float((~mech[np_]).mean()) if np_.any() else None,
               picard_to_nonpicard=float(mech[p_].mean()) if p_.any() else None)
    if frz is not None:
        out["cells_nonpicard_to_picard"] = float((1 - frz[np_]).mean()) if np_.any() else None
        out["cells_picard_to_nonpicard"] = float(frz[p_].mean()) if p_.any() else None
    return out


def cmat(rows, cols, rlab, clab):
    m = {r: {c: 0 for c in clab} for r in rlab}
    for a, b in zip(rows, cols):
        m[a][b] += 1
    return m


def logistic_cv(X, y, k=5, l2=1e-3, iters=60):
    """k-кратная CV log-loss логистической регрессии (Ньютон), X без свободного члена."""
    rng = np.random.default_rng(0)
    idx = rng.permutation(len(y))
    folds = np.array_split(idx, k)
    ll = []
    for f in folds:
        tr = np.setdiff1d(idx, f)
        A = np.c_[np.ones(len(tr)), X[tr]]
        w = np.zeros(A.shape[1])
        for _ in range(iters):
            p = 1 / (1 + np.exp(-A @ w))
            g = A.T @ (p - y[tr]) + l2 * w
            H = A.T @ (A * (p * (1 - p))[:, None]) + l2 * np.eye(len(w))
            w -= np.linalg.solve(H, g)
        B = np.c_[np.ones(len(f)), X[f]]
        p = np.clip(1 / (1 + np.exp(-B @ w)), 1e-9, 1 - 1e-9)
        ll.append(-np.mean(y[f] * np.log(p) + (1 - y[f]) * np.log(1 - p)))
    A = np.c_[np.ones(len(y)), X]
    w = np.zeros(A.shape[1])
    for _ in range(iters):
        p = 1 / (1 + np.exp(-A @ w))
        w -= np.linalg.solve(A.T @ (A * (p * (1 - p))[:, None]) + l2 * np.eye(len(w)), A.T @ (p - y) + l2 * w)
    return float(np.mean(ll)), w


def errors05(labs, cfg, route, S):
    """Ошибки маршрута по меткам ω = 0,5 (rerun_block → _labs) для конфига."""
    res = {}
    for d in "mh":
        mech, _, _ = route(cfg, S, d)
        r = {}
        for b in ("1000", "2000"):
            lab = labs[(d, b)]
            e = errs(lab, mech)
            r[f"nonpicard_to_picard_{b}"] = e["nonpicard_to_picard"]
            r[f"picard_to_nonpicard_{b}"] = e["picard_to_nonpicard"]
            r[f"n_nonpicard_{b}"] = e["n_nonpicard"]
            r[f"n_picard_{b}"] = e["n_picard"]
            r[f"n_uncertain_{b}"] = int((lab == 1).sum())
            r[f"n_nonpicard_sent_to_picard_{b}"] = int(((lab == 2) & ~mech).sum())
            r[f"n_picard_sent_to_mech_{b}"] = int(((lab == 0) & mech).sum())
        res[d] = r
    return res


def rerun_block(S, lm, lh, cfg, route, lev):
    """Метки по пересчёту rerun.py (ω = 0,5, холодный старт, до 2000 итераций) для случаев, которые рекомендованный конфиг
    отправляет в Пикар: ok — status 0 за ≤ 1000 итераций (бюджет игры) или ≤ 2000; hard — не сошлось и разброс ≥ 0,1·U_sat;
    иначе — неопределённо. Остальные случаи — метки ω = 1 (сходящиеся при ω = 1 считаются сходящимися и при 0,5: контроль)."""
    d = RUN_RERUN_DIR
    parts = sorted(d.glob("part-*.h5")) if d.exists() else []
    if not parts:
        return None
    rec = np.concatenate([h5py.File(p, "r")["cases"][:] for p in parts])
    sel = json.load(open(HERE / "selection.json"))["cases"]
    grp = {(r["case"], r["decision"], 1.0 if r["group"] == "repro_omega1" else 0.5): r["group"] for r in sel}
    idx = {int(c): i for i, c in enumerate(S["case"])}
    out = dict(n_done=int(len(rec)), n_selected=len(sel), dir=str(d))
    rep = rec[np.isclose(rec["omega"], 1.0)]
    if len(rep):
        out["repro_omega1"] = dict(n=int(len(rep)), still_nonconv=int((rep["status"] != 0).sum()),
                                   hc_maxdiff_m=float(rep["hc_maxdiff_m"].max()),
                                   spread_new_vs_s5=[[round(float(r["late_spread60_p90"]), 3), round(float(S["spread_m"][idx[int(r["case"])]]), 3)] for r in rep])
    r5 = rec[np.isclose(rec["omega"], 0.5)]
    usat = np.array([S["usat"][idx[int(c)]] for c in r5["case"]])
    ok1000 = (r5["status"] == 0) & (r5["iters"] <= 1000)
    ok2000 = r5["status"] == 0
    hard = (~ok2000) & (r5["late_spread60_p90"] >= HARD_SPREAD_REL * usat)
    g = np.array([grp.get((int(c), int(dd), 0.5), "?") for c, dd in zip(r5["case"], r5["decision"])])
    by = {}
    for gg in np.unique(g):
        for dd in (0, 1):
            m = (g == gg) & (r5["decision"] == dd)
            if m.any():
                by[f"{gg}_{'mh'[dd]}"] = dict(n=int(m.sum()), conv_le1000=float(ok1000[m].mean()), conv_le2000=float(ok2000[m].mean()),
                                              hard=float(hard[m].mean()), iters_conv_median=float(np.median(r5["iters"][m & ok2000])) if (m & ok2000).any() else None,
                                              spread_nonconv_median_rel=float(np.median((r5["late_spread60_p90"] / usat)[m & ~ok2000])) if (m & ~ok2000).any() else None)
    out["by_group"] = by
    labs = {}
    for dd, lab0 in ((0, lm), (1, lh)):
        for budget, okv in (("1000", ok1000), ("2000", ok2000)):
            lab = np.where(lab0 == 0, 0, -1)            # ok при ω = 1 → ok при ω = 0,5 (контроль 24 из 24); не-ok — только по пересчёту
            for c, ddd, o, h_, o2 in zip(r5["case"], r5["decision"], okv, hard, ok2000):
                if ddd == dd:
                    lab[idx[int(c)]] = 0 if o else (2 if (h_ or o2) else 1)   # сошлось только за > 1000 — для игры блуждание
            labs[("mh"[dd], budget)] = lab
    out["_labs"] = labs
    out["n_not_rerun_nonok"] = {f"{d}_{b}": int((v == -1).sum()) for (d, b), v in labs.items()}
    out["rule"] = ("ω = 0,5, холодный старт, max_outer 2000; бюджет игры — 1000 итераций (сошедшиеся за 1001–2000 — блуждание: "
                   "в игре их берёт запасной путь P12 v2). Все не-ok при ω = 1 случаи пересчитаны (и идущие в Пикар, и идущие "
                   "механизмам); сошедшиеся при ω = 1 считаются сошедшимися и при ω = 0,5 (контроль 24 из 24). Неперечитанные "
                   "не-ok (−1) в знаменатели не входят.")
    if cfg is None:
        return out
    out.pop("_labs", None)
    # клетки: сошедшиеся при ω = 0,5 решения «m» — местные фазы против рекомендованного классификатора
    conf = np.zeros((4, 5), np.int64)
    cond = _sy_cond_table()
    wh = {}
    for p in sorted(SY.glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            for j, c in enumerate(h["cases"][:]):
                wh[int(c["case"])] = (str(p), j)
    for p in parts:
        with h5py.File(p, "r") as h:
            cs = h["cases"][:]
            for k, c in enumerate(cs):
                if not (np.isclose(c["omega"], 0.5) and c["decision"] == 0 and c["status"] == 0):
                    continue
                f = h["fields"][k].astype(np.float64)
                path, j = wh[int(c["case"])]
                with h5py.File(path, "r") as g5:
                    hc = g5["inputs/hc"][j].astype(np.float64)
                row = dict(cond[(int(c["relief_id"]), int(c["cond_id"]))])
                tr = cell_truth(f[0, K25], f[1, K25], f[2, K600], hc, row["wind_from_deg"], row["u10_m_s"], row["alpha"], row["max_profile"])
                r = CR.classify(hc, row, None, "m", cfg)
                lab = cls_label(r["weights"], r["info"]["full"])
                np.add.at(conf, (tr[EDGE:-EDGE, EDGE:-EDGE].ravel(), lab[EDGE:-EDGE, EDGE:-EDGE].ravel()), 1)
    if conf.sum():
        out["cells_converged_omega05_recommended"] = dict(
            matrix={p: dict(zip(list(CR.PICARD) + ["mech"], map(int, conf[i]))) for i, p in enumerate(CR.PICARD)},
            acc_unfrozen=float(np.trace(conf[:, :4]) / max(conf[:, :4].sum(), 1)))
    return out


def stage_report():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    t0 = time.time()
    lev = ap8_levels()
    ap14 = json.load(open(AP14_SUMMARY)) if AP14_SUMMARY.exists() else None
    # ---------------- SY-12
    sy = json.load(open(OUT / "sy12_cls.json"))
    S = {k: np.array([r[k] for r in sy]) for k in sy[0] if not isinstance(sy[0][k], dict) and k[:3] != "tr_"}
    pc = dict(np.load(PER_CASE))
    o = np.argsort(pc["case"])
    pos = np.searchsorted(pc["case"][o], S["case"])
    P = {k: v[o][pos] for k, v in pc.items()}
    assert np.all(P["case"] == S["case"])
    lm = conv_label(S["status_m"], S["spread_m"], S["usat"])
    lh = conv_label(S["status_h"], S["spread_h"], S["usat"])
    # фазы истины по случаю
    def dtruth(stag, turn, rev):
        return ((stag >= lev["f_stag25"]).astype(int) + (turn >= lev["f_turn25"]) + (rev >= lev["f_rev25"])) >= 2
    Dm = dtruth(P["m_stag25"], P["m_turn25"], P["m_rev25"])
    Dh = dtruth(P["h_stag25"], P["h_turn25"], P["h_rev25"])
    tm = np.where(lm == 2, "N", np.where(lm == 1, "?", np.where(Dm, "D", "A")))
    th_ = np.where(lh == 2, np.where(lm == 0, "F", "N"), np.where(lh == 1, "?", np.where(Dh, "D", "A")))
    C_true = P["m_wmax600"] >= C_WMS
    cfg18 = CR.cfg_values(CR.CONFIG_AP18)

    def route(cfg, D=S, decision="m", with_g=False):
        """Маршрут случая. G (вечерний сток) в ошибки не входит: у Пикара нет потока тепла < 0 — сравнивать не с чем
        (with_g=True — полная заморозка, для доли механизмов)."""
        full, wH, wDs, wD = full_freeze(D, cfg)
        if decision == "m":
            frz = full.astype(float)
        else:
            frz = np.where(full, 1.0, np.minimum(1.0, D["f_frac"] + (D["g_frac"] if with_g else 0.0)))
        mech = frz >= 0.5
        ph = np.where(full, np.where(wH >= wDs, "H", "Ds"), np.where(wD >= 0.5, "D", "A"))
        if decision == "h":
            ph = np.where(~full & (D["f_frac"] >= 0.5), "F", np.where(~full & (D["g_frac"] >= 0.5), "G", ph))
        return mech, frz, ph

    rr0 = rerun_block(S, lm, lh, None, route, lev)
    labs05 = rr0["_labs"] if rr0 else None
    # подбор порогов: оси и центры, ошибка = np2p + p2np (hard против ok, решение «m»)
    def search(D, lab, axes_h, axes_s):
        res = []
        for ha, hgrid in axes_h:
            for hc_ in hgrid:
                for sa, sgrid in axes_s:
                    for sc_ in sgrid:
                        cfg = dict(cfg18, h_axis=ha, h_c=float(hc_), d_strong_axis=sa, d_strong_c=float(sc_ if sa != "none" else 1.0))
                        mech, frz, _ = route(cfg, D, "m")
                        e = errs(lab, mech)
                        res.append(dict(h_axis=ha, h_c=float(hc_), d_strong_axis=sa, d_strong_c=float(sc_), **e,
                                        cost=e["nonpicard_to_picard"] + e["picard_to_nonpicard"]))
        return res
    axes_h = [("fr", np.round(np.geomspace(0.08, 0.8, 31), 4)), ("u10", np.round(np.geomspace(0.3, 4.0, 41), 3))]
    axes_s = [("none", [0.0]), ("fr", np.round(np.geomspace(0.08, 0.6, 15), 4)), ("u_over_n", np.round(np.geomspace(80, 600, 19), 1))]
    grid_sy = search(S, lm, axes_h, axes_s)
    best_by = {}
    for r in grid_sy:
        k = (r["h_axis"], r["d_strong_axis"])
        if k not in best_by or r["cost"] < best_by[k]["cost"]:
            best_by[k] = r
    # оси по логистической регрессии (SY-12, «m»: hard против ok)
    sel = lm != 1
    y = (lm[sel] == 2).astype(float)
    feats = {"lg Fr": np.log10(S["fr"]), "lg U10": np.log10(S["u10"]), "lg U_sat/N": np.log10(S["u_over_n"]),
             "lg N": np.log10(S["nbv"]), "lg h": np.log10(np.maximum(S["relief"], 1.0))}
    lr = {}
    for name, keys in (("lg Fr", ["lg Fr"]), ("lg U10", ["lg U10"]), ("lg U_sat/N", ["lg U_sat/N"]),
                       ("lg U10 + lg Fr", ["lg U10", "lg Fr"]), ("lg U10 + lg N", ["lg U10", "lg N"]),
                       ("lg U10 + lg N + lg h", ["lg U10", "lg N", "lg h"])):
        X = np.c_[[feats[k][sel] for k in keys]].T
        ll, w = logistic_cv(X, y)
        lr[name] = dict(cv_logloss=round(ll, 4), coef=[round(float(x), 3) for x in w])
    # измеренная граница по U10 и Fr (1D логистика): центр и ширина в декадах
    def fit1(x):
        ll, w = logistic_cv(np.log10(x[sel])[:, None], y)
        return dict(center=float(10 ** (-w[0] / w[1])), w_dec=float(abs(1 / w[1])), cv_logloss=round(ll, 4))
    meas_u10, meas_fr, meas_uon = fit1(S["u10"]), fit1(S["fr"]), fit1(S["u_over_n"])
    # ---------------- идеальные
    rows = {r["key"]: r for r in json.load(open(OUT / "ideal_rows.json"))}
    icl = {r["key"]: r for r in json.load(open(OUT / "ideal_cls.json"))}
    keys = [k for k in rows if k in icl]
    I = {k: np.array([icl[x][k] for x in keys]) for k in ("fr", "u10", "usat", "nbv", "u_over_n", "f_frac", "b_area_km2", "c_frac")}
    I["g_frac"] = np.zeros(len(keys))
    R = {k: np.array([rows[x][k] for x in keys]) for k in ("status", "late_spread60_p90", "u_sat", "heat_flux_wm2", "f_stag25",
                                                          "f_turn25", "f_rev25", "f_wmax600", "lee_rev_area25_km2", "mech_case_id", "series")}
    plan = np.array([rows[x]["plan"] for x in keys])
    variant = np.array([rows[x]["variant"] for x in keys])
    R["iters"] = np.array([rows[x]["iters"] for x in keys])
    st_eff = np.where(R["iters"] > 1000, 1, R["status"])
    sp_eff = np.where((R["iters"] > 1000) & (R["status"] == 0), np.inf, R["late_spread60_p90"])
    li = conv_label(st_eff, sp_eff, R["u_sat"])
    # F: близнец без нагрева
    lab_by_key = dict(zip(keys, li))
    twin = np.array([lab_by_key.get(f"{p}:{int(m)}", -1) if m >= 0 else -1 for p, m in zip(plan, R["mech_case_id"])])
    Di = dtruth(R["f_stag25"], R["f_turn25"], R["f_rev25"])
    ti = np.where(li == 2, np.where((R["heat_flux_wm2"] > 0) & (twin == 0), "F", "N"), np.where(li == 1, "?", np.where(Di, "D", "A")))
    ideal_sets = {
        "ap_v1_grid": (plan == "ap_v1") & (R["series"] == SER_GRID),
        "ap_v2": plan == "ap_v2",
        "ap_v3_ctrl": (plan == "ap_v3") & (variant == "ctrl"),
        "ap_v3_omega": (plan == "ap_v3") & (variant == "omega"),
        "eroded": (plan == "ap_v1") & (R["series"] == SER_ERODED),
    }
    mech_ideal = (plan != "ap_v3") & (R["series"] != SER_ERODED) | (plan == "ap_v3") & np.isin(variant, ["omega"])
    grid_id = search({k: v[mech_ideal] for k, v in I.items()}, li[mech_ideal], axes_h, axes_s)
    best_id = {}
    for r in grid_id:
        k = (r["h_axis"], r["d_strong_axis"])
        if k not in best_id or r["cost"] < best_id[k]["cost"]:
            best_id[k] = r
    # ---------------- рекомендованный конфиг: пороги по Пикару игры (ω = 0,5 в полосе + запасное правило)
    # H: 50 % сходимости GRID после пересчёта AP-14 (ω = 0,5, 2000 итераций), среднее по H = 0/100/250, по lg Fr →
    # U10 через связь GRID (N = 0,01, h = 500): U10 = Fr·N·h/max_profile.
    cc = ap14["grid_conv_curve"]
    fr50 = []
    for hk, cv in cc.items():
        fr_ = np.array(cv["fr"]); af = np.array(cv["after"])
        j = int(np.argmax(af >= 0.5))
        if j > 0:
            x0, x1 = np.log10(fr_[j - 1]), np.log10(fr_[j]); y0_, y1_ = af[j - 1], af[j]
            fr50.append(10 ** (x0 + (0.5 - y0_) / max(y1_ - y0_, 1e-9) * (x1 - x0)))
    fr50 = float(np.exp(np.mean(np.log(fr50))))
    gm = (plan == "ap_v1") & (R["series"] == SER_GRID)
    k_u = float(np.median(I["u10"][gm] / I["fr"][gm]))            # U10 = k_u·Fr в GRID
    u_h = round(fr50 * k_u, 2)
    # сильное D / граница решателя: U_sat/N_c при ω = 0,5 (AP-13, хребет, три ветра; цензурированные — сверху — не берём)
    ap13 = json.load(open(AP / "analysis" / "AP-13" / "summary.json"))
    unc = []
    for us, nc in ap13["n_c_per_s_by_variant"]["omega"].items():
        cen = ap13["n_c"].get("omega", {}).get(us, {}).get("censored", "")
        if not cen and float(us) / nc < 1e4:
            unc.append(float(us) / nc)
    if not unc:
        unc = [float(us) / nc for us, nc in ap13["n_c_per_s_by_variant"]["omega"].items()][:2]
    l_c = round(float(np.exp(np.mean(np.log(unc)))), -1)
    nc0 = round(float(ap13["n_c_per_s_by_variant"]["omega"]["3.0"]), 4)
    p_nc = round(float(ap13["exponent_n_c_vs_u"]["omega"]["p"]), 2)
    # выбор U_sat/N_c по меткам ω = 0,5 (весь SY-12 не-ok пересчитан): минимум средней по «m» и «h» суммы ошибок
    # (бюджет 1000); центр H — из физики (u_h), для справки — соседние
    scan, l_c_ap13 = [], l_c
    if labs05:
        for hc_ in (0.6, u_h, 1.0):
            for un in (180.0, 200.0, 215.0, 230.0, 250.0, 270.0, 300.0):
                cfg_ = dict(cfg18, h_axis="u10", h_c=hc_, d_strong_axis="u_over_n", d_strong_c=un)
                e5 = errors05(labs05, cfg_, route, S)
                mi_, _, _ = route(cfg_, I, "h")
                eg = errs(li[gm], mi_[gm])
                cost = np.mean([e5[d]["nonpicard_to_picard_1000"] + e5[d]["picard_to_nonpicard_1000"] for d in "mh"])
                scan.append(dict(h_c=hc_, u_over_n_c=un, cost_sy12=round(float(cost), 4),
                                 sy12_m=[round(e5["m"]["nonpicard_to_picard_1000"], 3), round(e5["m"]["picard_to_nonpicard_1000"], 3)],
                                 sy12_h=[round(e5["h"]["nonpicard_to_picard_1000"], 3), round(e5["h"]["picard_to_nonpicard_1000"], 3)],
                                 grid=[round(eg["nonpicard_to_picard"], 3), round(eg["picard_to_nonpicard"], 3)]))
        best_un = min((r for r in scan if r["h_c"] == u_h), key=lambda r: r["cost_sy12"])
        l_c = best_un["u_over_n_c"]
    rec_s = dict(h_axis="u10", h_c=u_h, d_strong_axis="u_over_n", d_strong_c=l_c)
    cand = {
        "ap18": cfg18,
        "u10_only": dict(cfg18, h_axis="u10", h_c=u_h, d_strong_axis="none"),
        "u10+u_over_n (рекомендовано)": dict(cfg18, h_axis="u10", h_c=u_h, d_strong_axis="u_over_n", d_strong_c=l_c),
        "u10+nc_law": dict(cfg18, h_axis="u10", h_c=u_h, d_strong_axis="nc_law", d_strong_c=1.0, d_strong_nc0=nc0, d_strong_p=p_nc),
        "u10+u_over_n350": dict(cfg18, h_axis="u10", h_c=u_h, d_strong_axis="u_over_n", d_strong_c=350.0),
        "u10_1.26+u_over_n": dict(cfg18, h_axis="u10", h_c=round(meas_u10["center"], 2), d_strong_axis="u_over_n", d_strong_c=l_c),
        "u10+fr0.3": dict(cfg18, h_axis="u10", h_c=u_h, d_strong_axis="fr", d_strong_c=0.3),
        "sy12_opt_omega1": dict(cfg18, h_axis=best_by[("u10", "u_over_n")]["h_axis"], h_c=best_by[("u10", "u_over_n")]["h_c"],
                                d_strong_axis="u_over_n", d_strong_c=best_by[("u10", "u_over_n")]["d_strong_c"]),
        "ideal_opt_omega05": dict(cfg18, h_axis=min(best_id.values(), key=lambda r: r["cost"])["h_axis"],
                                  h_c=min(best_id.values(), key=lambda r: r["cost"])["h_c"],
                                  d_strong_axis=min(best_id.values(), key=lambda r: r["cost"])["d_strong_axis"],
                                  d_strong_c=min(best_id.values(), key=lambda r: r["cost"])["d_strong_c"]),
    }
    # ---------------- ERODED
    ero = json.load(open(OUT / "eroded.json"))
    vnames = [v for v, _ in ERO_VARIANTS]
    agg = {}
    tr_m = [e["tr"] for e in ero if "tr" in e]
    for v in vnames:
        bs = [e["variants"][v]["bound"] for e in ero]
        sp = [e["variants"][v]["speck"] for e in ero]
        nr = [e["variants"][v]["nreg"] for e in ero]
        ac = [e["variants"][v]["acc"] for e in ero if "acc" in e["variants"][v]]
        cf = np.sum([e["variants"][v]["conf"] for e in ero if "conf" in e["variants"][v]], axis=0)
        rcl = {p: float(cf[i, i] / max(cf[i].sum(), 1)) for i, p in enumerate(CR.PICARD) if cf[i].sum() > 0}
        agg[v] = dict(bound=float(np.mean(bs)), speck=float(np.mean(sp)), nreg=float(np.mean(nr)), acc=float(np.mean(ac)),
                      n_acc=len(ac), recall_A=rcl.get("A"), recall_B=rcl.get("B"), recall_C=rcl.get("C"), recall_D=rcl.get("D"),
                      macro_recall=float(np.mean(list(rcl.values()))))
    truth_speck = dict(bound=float(np.mean([t[0] for t in tr_m])), speck=float(np.mean([t[1] for t in tr_m])),
                       nreg=float(np.mean([t[2] for t in tr_m])), n=len(tr_m))
    # выбор: пятен (< 4 клеток) ≤ 0,1 % клеток и границ не больше, чем у поля; среди таких — максимум средней полноты
    # по фазам (balanced accuracy: A, B, C, D)
    def bal(a):
        return a["macro_recall"]
    ok = [v for v in vnames if agg[v]["speck"] <= 0.001 and agg[v]["bound"] <= truth_speck["bound"]]
    pool = ok if ok else vnames
    ero_best = max(pool, key=lambda v: bal(agg[v]))
    ero_ov = dict(ERO_VARIANTS)[ero_best]
    # ---------------- клетки SY-12
    cells = json.load(open(OUT / "sy12_cells.json"))
    cells_out = {}
    for v, m in cells.items():
        m = np.array(m)
        rec = {p: float(m[i, i] / max(m[i, :4].sum(), 1)) for i, p in enumerate(CR.PICARD)}
        prec = {p: float(m[i, i] / max(m[:, i].sum(), 1)) for i, p in enumerate(CR.PICARD)}
        cells_out[v] = dict(matrix={p: dict(zip(list(CR.PICARD) + ["mech"], map(int, m[i]))) for i, p in enumerate(CR.PICARD)},
                            recall=rec, precision=prec, frac_frozen=float(m[:, 4].sum() / m.sum()),
                            acc_unfrozen=float(np.trace(m[:, :4]) / max(m[:, :4].sum(), 1)), macro_recall=float(np.mean(list(rec.values()))))
    dloc_better = cells_out["dloc100_C"]["macro_recall"] > cells_out["ap18_C"]["macro_recall"]
    # ---------------- конфиг
    rec_cfg = dict(CR.CONFIG_AP18)
    rec_cfg.update({
        "h_axis": "u10", "h_axis_doc": "AP-23: ось штиля — U10 (штиль — слабый ветер). На SY-12 одиночная ось U10 разделяет блуждание Пикара лучше Fr (CV log-loss в summary.json → axes_logistic); по Fr в SY-12 при U10 ≥ 3 м/с и Fr < 0,25 Пикар сходится в 95–100 % случаев.",
        "h_c": rec_s["h_c"], "h_c_doc": f"AP-23: 50 % сходимости Пикара с ω = 0,5 (GRID после пересчёта AP-14, Fr {fr50:.2f} ⇔ U10 {u_h:.2f} м/с; AP-9: при ω = 0,5 сходится 0,41 при U10 < 1 и 0,89 при 1–1,5 м/с). На SY-12 (ω = 1) центр {meas_u10['center']:.2f} м/с — выше на сдвиг ω (AP-13: ×1,4 по N).",
        "h_w_dec": round(min(max(meas_u10["w_dec"], 0.05), 0.3), 2), "h_w_dec_doc": f"AP-23: ширина логистики P(блуждание) по lg U10 на SY-12 — {meas_u10['w_dec']:.2f} дек (граница не резкая: рельеф и N сдвигают её).",
        "d_strong_axis": "u_over_n", "d_strong_axis_doc": "AP-23: сильное D — по U_sat/N (м), не по Fr: на SY-12 при U10 ≥ 3 м/с и Fr 0,15–0,25 Пикар сходится в 95–100 % случаев (заморозка по Fr < 0,3 отдаёт механизмам сходящиеся случаи), а несходимость без штиля следует U/N (AP-7, AP-13). При U/N < 270 м и рельефе h > 270 м Nh/U > 1 — течение у земли блокировано (D), и Пикар с ω = 0,5 его не сводит.",
        "d_strong_c": l_c, "d_strong_c_doc": f"AP-23: минимум суммы ошибок маршрута на SY-12 по меткам пересчёта ω = 0,5 (бюджет 1000 итераций, все не-ok пересчитаны; summary.json → threshold_scan) — {l_c:.0f} м; для сравнения U_sat/N_c при ω = 0,5 по AP-13 (хребет): {', '.join(f'{x:.0f}' for x in unc)} м.",
        "d_local": bool(dloc_better), "d_local_doc": "AP-23: D по клеткам ниже разделяющей линии тока H_c = base + (h_max − base)(1 − Fr) [Sheppard 1956; Snyder 1985] — точность по клеткам SY-12 выше, чем однородное D (summary.json → confusion_sy12_cells).",
        "d_local_ramp_m": float(ero_ov["d_local_ramp_m"]) if ero_ov["d_local"] else 100.0,
        "d_local_ramp_m_doc": "AP-23: переход по H_c − h, м — по ERODED (меньше «шахматки» при той же точности).",
        "c_w_ms": C_WMS, "c_w_ms_doc": "AP-23: фаза C (волны) по клеткам: U_sat·|e·∇h_s| ≥ 1 м/с (min_sink), h_s сглажен на U/N; гидростатические волны w ≈ U ∂h/∂x [Smith 1979].",
        "b_depth_m": float(ero_ov["b_depth_m"]), "b_depth_m_doc": "AP-23: глубина под огибающей до полного B — по ERODED (без «шахматки»: доля пятен < 4 клеток ≤ 1 %, граница не чаще, чем у истины).",
        "smooth_cells": float(ero_ov["smooth_cells"]), "smooth_cells_doc": "AP-23: гаусс по весам, клетки — по ERODED (см. b_depth_m_doc).",
        "d_w_dec": 0.10, "d_w_dec_doc": "AP-8: на идеальных формах 0,02–0,03 дек; AP-11: на эрозии 0,05–0,12 — 0,10 оставлено (AP-18).",
    })
    rec_vals = CR.cfg_values(rec_cfg)
    # ---------------- матрицы и ошибки для AP-18 и рекомендованного
    out_err, conf_cases, conf_ideal = {}, {}, {}
    rl = ["A", "D", "N", "F", "?"]
    for name, cfg in (("ap18", cfg18), ("recommended", rec_vals)):
        mm, fm, phm = route(cfg, S, "m")
        mh, fh, phh = route(cfg, S, "h")
        om = omega_v(S, cfg)
        e_m, e_h = errs(lm, mm, fm), errs(lh, mh, fh)
        npp = (lm == 2) & ~mm
        e_m["nonpicard_to_picard_in_omega_band"] = float((om[npp] < 1).mean()) if npp.any() else None
        cl = ["A", "D", "H", "Ds", "F", "G"]
        conf_cases[name] = dict(m=cmat(tm, phm, rl, cl), h=cmat(th_, phh, rl, cl))
        mi, fi, phi = route(cfg, I, "h")
        ei = {}
        for sname, msk in ideal_sets.items():
            ei[sname] = errs(li[msk], mi[msk], fi[msk])
        conf_ideal[name] = {sname: cmat(ti[msk], phi[msk], rl, cl) for sname, msk in ideal_sets.items()}
        e_m["nonpicard_to_picard_outside_omega_band"] = float(((lm == 2) & ~mm & (om >= 1)).sum() / max((lm == 2).sum(), 1))
        mg, fg, _ = route(cfg, S, "h", with_g=True)
        e_h["mech_share_with_G"] = float(mg.mean())
        e_h["g_freeze_ge05_cases"] = int(((S["g_frac"] >= 0.5) & ~mh).sum())
        out_err[name] = dict(sy12_m=e_m, sy12_h=e_h, ideal=ei)
        if labs05:
            out_err[name]["sy12_omega05"] = errors05(labs05, cfg, route, S)
    cand_tab = {}
    for name, cfg in cand.items():
        mm, _, _ = route(cfg, S, "m")
        mh, _, _ = route(cfg, S, "h")
        mi, _, _ = route(cfg, I, "h")
        om = omega_v(S, cfg)
        row = dict(cfg={k: cfg[k] for k in ("h_axis", "h_c", "d_strong_axis", "d_strong_c")})
        q = errs(lm, mm); row["sy12_m_omega1"] = [round(q["nonpicard_to_picard"], 3), round(q["picard_to_nonpicard"], 3)]
        if labs05:
            e5 = errors05(labs05, cfg, route, S)
            row["sy12_m_omega05"] = [round(e5["m"]["nonpicard_to_picard_1000"], 3), round(e5["m"]["picard_to_nonpicard_1000"], 3)]
            row["sy12_h_omega05"] = [round(e5["h"]["nonpicard_to_picard_1000"], 3), round(e5["h"]["picard_to_nonpicard_1000"], 3)]
        row["sy12_m_np2p_outside_band"] = round(float(((lm == 2) & ~mm & (om >= 1)).sum() / max((lm == 2).sum(), 1)), 3)
        q = errs(lh, mh); row["sy12_h_omega1"] = [round(q["nonpicard_to_picard"], 3), round(q["picard_to_nonpicard"], 3)]
        for sname, msk in ideal_sets.items():
            q = errs(li[msk], mi[msk])
            row[sname] = [None if q[k] is None else round(q[k], 3) for k in ("nonpicard_to_picard", "picard_to_nonpicard")]
        cand_tab[name] = row
    # B и C — есть/нет
    Bt = R["lee_rev_area25_km2"] >= B_AREA_KM2
    Bc = I["b_area_km2"] >= B_AREA_KM2
    Ct = R["f_wmax600"] >= C_WMS
    Cc = I["c_frac"] * 96 * 96 >= 2
    okI = (li == 0) & np.isin(plan, ["ap_v1", "ap_v2"]) & (R["series"] != SER_ERODED)
    def tab2(t, c, m):
        return {"true_yes": {"cls_yes": int((t & c & m).sum()), "cls_no": int((t & ~c & m).sum())},
                "true_no": {"cls_yes": int((~t & c & m).sum()), "cls_no": int((~t & ~c & m).sum())}}
    presence = dict(ideal_B=tab2(Bt, Bc, okI & np.isfinite(R["lee_rev_area25_km2"])), ideal_C=tab2(Ct, Cc, okI),
                    sy12_C=tab2(C_true, S["c_frac"] * 96 * 96 >= 2, lm == 0))
    # F: тепловая несходимость против w*/U10 (SY-12) и заморозка F
    heat_caused = (lh == 2) & (lm == 0)
    wsu = S["wstar_over_u"]
    f_curve = []
    for a, b in ((0, 0.6), (0.6, 0.8), (0.8, 1.0), (1.0, 1.3), (1.3, 2.0), (2.0, 1e9)):
        m = (wsu >= a) & (wsu < b) & (lm == 0) & (lh != 1)
        f_curve.append(dict(w_star_over_u10=[a, b], n=int(m.sum()), heat_caused=float(heat_caused[m].mean()) if m.any() else None,
                            f_freeze_ge05=float((S["f_frac"][m] >= 0.5).mean()) if m.any() else None))
    g_stats = dict(n_active=int(S["g_active"].sum()), n_wG_mean_gt01=int((S["wG_mean"] > 0.1).sum()),
                   n_g_freeze_ge05=int((S["g_frac"] >= 0.5).sum()), n_g_freeze_any=int((S["g_frac"] > 0).sum()),
                   conv_h_among_g_active=float((lh[S["g_active"]] == 0).mean()))
    # ---------------- границы против измеренных
    w11 = json.load(open(AP / "analysis" / "AP-11" / "summary.json"))["rows"]
    def w_er(p):
        ws = [r["w_dec"] for r in w11 if r["param"] == p and r["ok"]]
        return float(np.median(ws)) if ws else None
    pp = ap14["bounds"]["per_param"] if ap14 else {}
    def a14(p):
        q = pp.get(p, {}).get("clean_after") or {}
        return dict(fr_c_median=q.get("fr_c_median"), p25_p75=q.get("fr_c_p25_p75"), w_dec_median=q.get("w_dec_median"))
    conv_curve = ap14["grid_conv_curve"]["0.0"] if ap14 else None
    fr50_after = None
    if conv_curve:
        fr_ = np.array(conv_curve["fr"]); af = np.array(conv_curve["after"])
        fr50_after = float(fr_[np.argmax(af >= 0.5)])
    bvm = [
        dict(boundary="H (штиль, заморозка)", classifier_ap18="Fr < 0,25 (w 0,05)", recommended=f"U10 < {rec_vals['h_c']} м/с (w {rec_vals['h_w_dec']})",
             measured=dict(sy12_u10_center_ms=meas_u10, sy12_fr_center=meas_fr, sy12_u_over_n_center_m=meas_uon,
                           ap14_grid_H0_fr_conv50_after=fr50_after, ap14_conv_fr_c_clean_after=a14("conv"),
                           ap9_calm="Fr ≤ 0,25 (U10 ≤ 0,5 м/с) не сходится и при ω = 0,5"),
             note="Fr и U10 в GRID связаны (N, h постоянны); в SY-12 h 240–2700 м, Fr 0,25 ⇔ U_sat 0,6–6,8 м/с"),
        dict(boundary="D (блокирование, вес)", classifier_ap18="Fr_c 1,0, w 0,10", recommended="то же" + (", по клеткам ниже H_c" if rec_vals["d_local"] else ""),
             measured=dict(ap14_f_stag25=a14("f_stag25"), ap14_f_turn25=a14("f_turn25"), ap14_f_rev25=a14("f_rev25"),
                           ap11_eroded_w_dec=dict(f_turn25=w_er("f_turn25"), lee_rev_area25_km2=w_er("lee_rev_area25_km2"),
                                                  conv=w_er("conv"), spread_rel=w_er("spread_rel")))),
        dict(boundary="сильное D (заморозка)", classifier_ap18="Fr < 0,3", recommended=f"{rec_vals['d_strong_axis']} {rec_vals['d_strong_c']}",
             measured=dict(sy12_best_by_axis={f"{k[0]}+{k[1]}": dict(h_c=v["h_c"], d_strong_c=v["d_strong_c"], cost=round(v["cost"], 4),
                                                                      np2p=round(v["nonpicard_to_picard"], 4), p2np=round(v["picard_to_nonpicard"], 4))
                                               for k, v in best_by.items()},
                           ideal_best_by_axis={f"{k[0]}+{k[1]}": dict(h_c=v["h_c"], d_strong_c=v["d_strong_c"], cost=round(v["cost"], 4))
                                               for k, v in best_id.items()})),
        dict(boundary="B (срыв)", classifier_ap18="огибающая 12° (tg = 0,21), глубина 50 м", recommended=f"12°, глубина {rec_vals['b_depth_m']} м",
             measured=dict(ap10_reverse_onset_slope="хребет 0,20–0,25, уступ и холм 0,25–0,30; по Fr порога нет (0,3–5)",
                           ap14_lee_rev_area25=a14("lee_rev_area25_km2"))),
        dict(boundary="F (конвекция)", classifier_ap18="−z_i/L 35 (w 0,2); заморозка w* ≥ U_sat", recommended="то же",
             measured=dict(ap14_th_ceil_over_zi=a14("th_ceil_over_zi"), sy12_heat_caused_by_wstar_over_u10=f_curve,
                           ap7="тепловая несходимость 0,90 при w*/U10 0,8–1, 0,44 при 1–1,3 (идеальные, H = 250)")),
        dict(boundary="ω-полоса", classifier_ap18="Fr 0,3–1,1 или U10 0,6–1,5 м/с → ω 0,5", recommended="то же",
             measured=dict(ap14="при ω = 0,5 GRID H = 0 сходится весь при Fr ≥ 0,5; ниже — 0,30–0,67")),
    ]
    # ---------------- пересчёт при ω = 0,5 (rerun.py): метки маршрута «как в игре»
    rerun_res = rerun_block(S, lm, lh, rec_vals, route, lev)
    if rerun_res:
        rerun_res.pop("_labs", None)
        rerun_res["errors_omega05"] = out_err["recommended"]["sy12_omega05"]
        rerun_res["errors_omega05_ap18"] = out_err["ap18"]["sy12_omega05"]
    # ---------------- вердикт
    e = out_err["recommended"]
    crit = dict(sy12_m_np2p_outside_omega_band_max=0.05, sy12_m_np2p_max=0.15, sy12_m_p2np_max=0.10, ideal_grid_np2p_max=0.15, ideal_grid_p2np_max=0.10, cells_acc_min=0.6, eroded_speck_max=0.01)
    checks = dict(sy12_m_np2p_outside_band=e["sy12_m"]["nonpicard_to_picard_outside_omega_band"] <= crit["sy12_m_np2p_outside_omega_band_max"],
                  sy12_m_np2p_omega1=e["sy12_m"]["nonpicard_to_picard"] <= crit["sy12_m_np2p_max"],
                  sy12_m_p2np=e["sy12_m"]["picard_to_nonpicard"] <= crit["sy12_m_p2np_max"],
                  ideal_np2p=(e["ideal"]["ap_v1_grid"]["nonpicard_to_picard"] or 0) <= crit["ideal_grid_np2p_max"],
                  ideal_p2np=(e["ideal"]["ap_v1_grid"]["picard_to_nonpicard"] or 0) <= crit["ideal_grid_p2np_max"],
                  cells_acc=max(c["acc_unfrozen"] for c in cells_out.values()) >= crit["cells_acc_min"],
                  eroded_speck=agg[ero_best]["speck"] <= crit["eroded_speck_max"])
    if rerun_res and rerun_res.get("errors_omega05"):
        e5 = rerun_res["errors_omega05"]
        crit["sy12_m_np2p_omega05_max"] = crit.pop("sy12_m_np2p_max")
        checks.pop("sy12_m_np2p_omega1")
        checks["sy12_m_np2p_omega05"] = e5["m"]["nonpicard_to_picard_1000"] <= crit["sy12_m_np2p_omega05_max"]
        checks["sy12_m_p2np"] = e5["m"]["picard_to_nonpicard_1000"] <= crit["sy12_m_p2np_max"]
    verdict = "ready" if all(checks.values()) else "needs_work"
    # ---------------- рисунки
    fig, ax = plt.subplots(1, 3, figsize=(13, 3.6))
    for a, (x, lab, edges) in zip(ax, ((S["u10"], "U10, м/с", np.geomspace(0.5, 20, 16)), (S["fr"], "Fr", np.geomspace(0.05, 30, 16)),
                                      (S["u_over_n"], "U_sat/N, м", np.geomspace(50, 1e4, 16)))):
        cx, fy, fs = [], [], []
        for lo, hi in zip(edges[:-1], edges[1:]):
            m = (x >= lo) & (x < hi)
            if m.sum() >= 5:
                cx.append(np.sqrt(lo * hi)); fy.append((lm[m] == 2).mean()); fs.append((lm[m] == 1).mean())
        a.plot(cx, fy, "o-", label="блуждание ≥ 0,1·U_sat")
        a.plot(cx, fs, "s--", label="неопределённо (ω = 1)")
        a.set_xscale("log"); a.set_xlabel(lab); a.set_ylim(0, 1); a.grid(alpha=0.3)
    ax[0].axvline(rec_vals["h_c"], color="k", ls=":", label="рекомендовано")
    ax[1].axvline(0.25, color="r", ls=":", label="AP-18 H"); ax[1].axvline(0.3, color="m", ls=":", label="AP-18 сильное D")
    ax[0].set_ylabel("доля случаев SY-12 («m»)"); ax[0].legend(fontsize=7); ax[1].legend(fontsize=7)
    fig.tight_layout(); fig.savefig(HERE / "fig_sy12_wander_axes.png", dpi=110); plt.close(fig)
    fig, ax = plt.subplots(figsize=(5.5, 4.5))
    for (ha, sa), mk in zip(best_by, "os^vD<>x"):
        rr = [r for r in grid_sy if r["h_axis"] == ha and r["d_strong_axis"] == sa]
        ax.scatter([r["picard_to_nonpicard"] for r in rr], [r["nonpicard_to_picard"] for r in rr], s=6, marker=mk, label=f"H:{ha}, сильное D:{sa}", alpha=0.5)
    for name, c in (("AP-18", "r"), ("рекомендовано", "k")):
        q = out_err["ap18" if name == "AP-18" else "recommended"]["sy12_m"]
        ax.plot(q["picard_to_nonpicard"], q["nonpicard_to_picard"], "*", ms=14, color=c, label=name)
    ax.set_xlabel("Пикар-ok → механизм (доля)"); ax.set_ylabel("блуждание → Пикар (доля)"); ax.set_xlim(0, 0.5); ax.set_ylim(0, 1)
    ax.legend(fontsize=6); ax.grid(alpha=0.3); fig.tight_layout(); fig.savefig(HERE / "fig_routing_errors.png", dpi=110); plt.close(fig)
    fig, ax = plt.subplots(1, len(cells_out), figsize=(4 * len(cells_out), 3.6))
    for a, (v, c) in zip(np.atleast_1d(ax), cells_out.items()):
        m = np.array([[c["matrix"][r][k] for k in list(CR.PICARD) + ["mech"]] for r in CR.PICARD], float)
        a.imshow(m / np.maximum(m.sum(1, keepdims=True), 1), vmin=0, vmax=1, cmap="Blues")
        for i in range(4):
            for j in range(5):
                a.text(j, i, f"{m[i, j] / max(m[i].sum(), 1):.2f}", ha="center", va="center", fontsize=7)
        a.set_xticks(range(5), list(CR.PICARD) + ["мех."]); a.set_yticks(range(4), CR.PICARD)
        a.set_title(v, fontsize=9); a.set_xlabel("классификатор"); a.set_ylabel("по полю")
    fig.tight_layout(); fig.savefig(HERE / "fig_confusion_cells.png", dpi=110); plt.close(fig)
    fig, ax = plt.subplots(figsize=(6, 4.2))
    xs = [agg[v]["speck"] for v in vnames]; ys = [bal(agg[v]) for v in vnames]
    ax.scatter(xs, ys, c=[dict(ERO_VARIANTS)[v]["smooth_cells"] for v in vnames], cmap="viridis", s=18)
    ax.axvline(truth_speck["speck"], color="k", ls=":", label="истина (поле)")
    ax.plot(agg[ero_best]["speck"], bal(agg[ero_best]), "r*", ms=14, label=ero_best)
    ax.set_xlabel("доля клеток в пятнах < 4 клеток"); ax.set_ylabel("точность (баланс A/B/D)"); ax.legend(fontsize=7); ax.grid(alpha=0.3)
    fig.tight_layout(); fig.savefig(HERE / "fig_eroded_speck.png", dpi=110); plt.close(fig)
    fig, ax = plt.subplots(figsize=(6, 4.5))
    msk = np.isin(plan, ["ap_v1", "ap_v2"]) & (R["series"] != SER_ERODED)
    for t, c in (("A", "tab:green"), ("D", "tab:blue"), ("N", "tab:red"), ("F", "tab:orange"), ("?", "0.6")):
        m = msk & (ti == t)
        ax.scatter(I["u10"][m], I["fr"][m], s=8, c=c, label=t, alpha=0.6)
    ax.axvline(rec_vals["h_c"], color="k", ls=":"); ax.axhline(0.25, color="r", ls=":")
    ax.set_xscale("log"); ax.set_yscale("log"); ax.set_xlabel("U10, м/с"); ax.set_ylabel("Fr"); ax.legend(fontsize=7, title="по решению")
    fig.tight_layout(); fig.savefig(HERE / "fig_ideal_plane.png", dpi=110); plt.close(fig)
    # ---------------- summary
    summ = dict(
        task="AP-23", contract="P15 v1", seconds=round(time.time() - t0, 1),
        inputs=dict(sy12=str(SY), conditions=str(SYC), per_case=str(PER_CASE), ideal=["features_ap_v1_merged.h5 (GRID, ERODED)", "features_ap_v2_merged.h5", "ap_v3__s1-ee7be55 parts"],
                    ap14_summary=str(AP14_SUMMARY), note_ap14="features_ap_v1r.h5 входит в *_merged.h5 (правило AP-14: исходный случай, если сошёлся, иначе пересчёт ω = 0,5)"),
        truth_rules=dict(TRUTH_RULES, levels_ap8=lev),
        classifier="tools/research/air_phase/classifier_ref.py (AP-18: hybrid/pipeline + assembly/assemble.classify, фазы P10)",
        n=dict(sy12=len(sy), sy12_m={k: int((lm == v).sum()) for k, v in (("ok", 0), ("uncertain", 1), ("hard", 2))},
               sy12_h={k: int((lh == v).sum()) for k, v in (("ok", 0), ("uncertain", 1), ("hard", 2))},
               ideal={s: int(m.sum()) for s, m in ideal_sets.items()}),
        confusion_ideal=conf_ideal, confusion_sy12_cases=conf_cases, confusion_sy12_cells=cells_out, presence_B_C=presence,
        err_nonpicard_to_picard={k: dict(**({"sy12_m_omega05": v["sy12_omega05"]["m"]["nonpicard_to_picard_1000"],
                                             "sy12_h_omega05": v["sy12_omega05"]["h"]["nonpicard_to_picard_1000"]} if "sy12_omega05" in v else {}),
                                         sy12_m_cases=v["sy12_m"]["nonpicard_to_picard"], sy12_h_cases=v["sy12_h"]["nonpicard_to_picard"],
                                         sy12_m_cells=v["sy12_m"]["cells_nonpicard_to_picard"], sy12_h_cells=v["sy12_h"]["cells_nonpicard_to_picard"],
                                         in_omega_band=v["sy12_m"]["nonpicard_to_picard_in_omega_band"],
                                         ideal={s: q["nonpicard_to_picard"] for s, q in v["ideal"].items()}) for k, v in out_err.items()},
        err_picard_to_nonpicard={k: dict(**({"sy12_m_omega05": v["sy12_omega05"]["m"]["picard_to_nonpicard_1000"],
                                             "sy12_h_omega05": v["sy12_omega05"]["h"]["picard_to_nonpicard_1000"]} if "sy12_omega05" in v else {}),
                                         sy12_m_cases=v["sy12_m"]["picard_to_nonpicard"], sy12_h_cases=v["sy12_h"]["picard_to_nonpicard"],
                                         sy12_m_cells=v["sy12_m"]["cells_picard_to_nonpicard"], sy12_h_cells=v["sy12_h"]["cells_picard_to_nonpicard"],
                                         ideal={s: q["picard_to_nonpicard"] for s, q in v["ideal"].items()}) for k, v in out_err.items()},
        errors_full=out_err, candidates=dict(note="[блуждание → Пикар, Пикар-ok → механизм]; ошибки по случаям; SY-12 — счёт ω = 1, идеальные ap_v1/ap_v2 — после пересчёта AP-14 (ω = 0,5), ap_v3_ctrl — ω = 1, ap_v3_omega — ω = 0,5", table=cand_tab),
        thresholds_derivation=dict(fr50_grid_omega05=fr50, u10_per_fr_grid=k_u, u_over_n_c_omega05_m=unc, u_over_n_c_ap13_m=l_c_ap13),
        threshold_scan=dict(note="SY-12 [блуждание → Пикар, ok → механизм] по меткам ω = 0,5, бюджет 1000; GRID — после AP-14", table=scan), axes_logistic=lr, boundaries_vs_measured=bvm, f_heat=f_curve, g_stats=g_stats,
        eroded=dict(truth=truth_speck, best=ero_best, best_metrics=agg[ero_best], ap18_like=agg["b50_s1_d0"], all=agg),
        rerun_omega05=rerun_res, recommended_config=rec_cfg, verdict=verdict, verdict_criteria=dict(crit, _status="утверждены координатором, предварительные (06.10)"), verdict_checks=checks,
    )
    json.dump(summ, open(HERE / "summary.json", "w"), ensure_ascii=False, indent=1, default=float)
    print(json.dumps(dict(verdict=verdict, checks=checks, cand=cand_tab, best=rec_s, fr50=fr50, ero_best=ero_best, lr=lr, meas_u10=meas_u10,
                          meas_fr=meas_fr, meas_uon=meas_uon), ensure_ascii=False, default=float)[:6000])


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", default="all", choices=["prep", "report", "all"])
    ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args()
    if a.stage in ("prep", "all"):
        stage_prep(a.workers)
    if a.stage in ("report", "all"):
        stage_report()
