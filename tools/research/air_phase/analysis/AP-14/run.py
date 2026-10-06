"""AP-14: пересчёт несошедшихся случаев ap_v1/ap_v2 при ω = 0,5 и 2000 итерациях (план ap_v1r, серия RERUN) —
сходимость, позднее среднее против неподвижной точки, границы фаз AP-8 на объединённых данных. Только CPU.

    PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
    $PY tools/research/air_phase/analysis/AP-14/run.py [--workers 16] [--n-boot 200] [--stage all|merge|fields|fits|report]

Вход: таблицы признаков P6 `$AIR_SYNTH_DATA/phase/features_{ap_v1,ap_v2,ap_v1r}.h5`, план `ap_v1r` (src_plan/
src_case_ids), части P3 `ap_v1__s1-74644c4`, `ap_v2__s1-74644c4` и `ap_v1r__<версия>`.
Выход (P7): `summary.json`, `section.md` (пишется вручную по summary), `fig_*.png`; объединённые таблицы
`$AIR_SYNTH_DATA/phase/features_ap_v1_merged.h5`, `features_ap_v2_merged.h5` (исходный случай, если сошёлся, иначе
пересчёт; поля `rr_used`, `rr_case_id`, `rr_status`, `src_status`); кэш подгонок и отчёты AP-8 «до/после» —
`tools/research/air_phase/out/AP-14/{before,after}/`.

Что считается:
1. Сходимость после ω = 0,5: доля status 0 по исходной серии, Fr, H, h/z_i, форме, h (ap_v2), N; итерации.
2. Позднее среднее (ω = 1, 1000 итераций) против неподвижной точки (ω = 0,5, сошлось): |Δu_h| ≤ 600 м (p90, p99,
   max в долях U_sat; p90 на 50 м в м/с против late_spread60_p90 исходного случая — «в области блуждания или нет»),
   разности метрик слоёв `layer_diff` (ключи и физические минимумы — как AP-8).
3. Подгонки AP-8 (`analysis/AP-8/run.py`: `stage_fits`, `stage_report` — без изменений) на исходной таблице ap_v1
   («до») и на объединённой («после»); сравнение принятых границ по (линия GRID, параметр): Fr_c, w, класс,
   in_gap; агрегаты по параметрам.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path

import h5py
import numpy as np

HERE = Path(__file__).resolve().parent
AP = HERE.parents[1]
sys.path.insert(0, str(AP))
import phase_io as PIO  # noqa: E402
from layer_metrics import layer_diff  # noqa: E402

pb = PIO.pb
DATA = Path(os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data"))) / "phase"
SRC = {"ap_v1": DATA / "ap_v1__s1-74644c4", "ap_v2": DATA / "ap_v2__s1-74644c4"}
RR_PLAN = DATA / "ap_v1r"
OUT = AP / "out" / "AP-14"
EDGE = 5
KEEP = {"case_id", "line_id", "k", "series", "relief_id", "start_case_id", "ref_case_id", "ref400_case_id",
        "mech_case_id", "variant", "shape", "slope", "h_m", "h_over_zi", "relief_name", "src_case_id", "batch_size"}

_spec = importlib.util.spec_from_file_location("ap8", HERE.parent / "AP-8" / "run.py")
ap8 = importlib.util.module_from_spec(_spec)
sys.modules["ap8"] = ap8          # для пула процессов (pickle функций AP-8)
_spec.loader.exec_module(ap8)


def dec(v):
    return v.decode() if isinstance(v, (bytes, np.bytes_)) else v


def rr_results():
    got = [d for d in sorted(DATA.glob("ap_v1r__*")) if any(d.glob("part-*.h5"))]
    assert len(got) == 1, got
    return got[0]


def load(name):
    with h5py.File(DATA / f"features_{name}.h5", "r") as h:
        return h["features"][:]


# ------------------------------------------------------------------ 1. объединение
def src_map():
    """case_id ap_v1r → (src_plan, src_case_id)."""
    _, _, lines, _, cases = PIO.load_plan(RR_PLAN)
    return {c.case_id: (lines[c.line_id].src_plan, c.src_case_id) for c in cases}


def merge(src_tab, rr_tab, plan_name, sm):
    """Исходный случай, если сошёлся, иначе пересчёт (любой статус). Новые поля rr_used, rr_case_id, rr_status,
    src_status. ref_iou_* у заменённых — NaN (опорные поля не пересчитывались)."""
    by_src = {sm[int(c)][1]: q for q, c in enumerate(rr_tab["case_id"]) if sm[int(c)][0] == plan_name}
    dt = np.dtype([(n, src_tab.dtype[n]) for n in src_tab.dtype.names] + [("rr_used", "i1"), ("rr_case_id", "i8"), ("rr_status", "i1"),
                                         ("src_status", "i1")])
    out = np.zeros(len(src_tab), dt)
    for n in src_tab.dtype.names:
        out[n] = src_tab[n]
    out["rr_case_id"], out["rr_status"], out["src_status"] = -1, -1, src_tab["status"]
    common = [n for n in src_tab.dtype.names if n in rr_tab.dtype.names and n not in KEEP]
    nrep = 0
    for q, cid in enumerate(src_tab["case_id"]):
        r = by_src.get(int(cid))
        if r is None:
            continue
        out["rr_case_id"][q], out["rr_status"][q] = rr_tab["case_id"][r], rr_tab["status"][r]
        if src_tab["status"][q] == 0:
            continue
        for n in common:
            out[n][q] = rr_tab[n][r]
        for g in ("th", "sl", "lee"):
            if f"ref_iou_{g}" in dt.names:
                out[f"ref_iou_{g}"][q] = np.nan
        out["rr_used"][q] = 1
        nrep += 1
    return out, nrep


def write_merged(tab, name):
    path = DATA / f"features_{name}_merged.h5"
    tmp = path.with_suffix(".h5.tmp")
    with h5py.File(tmp, "w") as h:
        h.create_dataset("features", data=tab, compression="gzip", compression_opts=4, shuffle=True)
        h.attrs.update(contract="P6 v2 + AP-14", source=str(DATA / f"features_{name}.h5"),
                       rerun=str(DATA / "features_ap_v1r.h5"),
                       rule="исходный случай, если сошёлся (status 0), иначе пересчёт ap_v1r (ω = 0,5, 2000 итераций)")
    os.replace(tmp, path)
    return path


# ------------------------------------------------------------------ 2. сходимость
REL_TOL = 4e-4      # batch_solver: resid_rel = resid·a/U_sat² < 4e-4 ⇔ относительный критерий P4 (= абсолютный при U_sat = 5 м/с)
_STRICT = {}


def frac(m, ok):
    """Доля сошедшихся (абсолютный критерий P4) и строгая — ещё и resid_rel ≤ REL_TOL (при U_sat < 5 м/с абсолютный
    порог мягче относительного: при U_sat = 0,6 м/с — в 70 раз)."""
    n = int(m.sum())
    st = _STRICT.get("v")
    d = dict(n=n, conv=int((ok & m).sum()), frac=round(float((ok & m).sum() / n), 3) if n else None)
    if st is not None and st.shape == m.shape:
        d["frac_rel_strict"] = round(float((ok & st & m).sum() / n), 3) if n else None
    return d


def convergence(rr, sm, src_tabs):
    pos = {k: {int(c): q for q, c in enumerate(t["case_id"])} for k, t in src_tabs.items()}
    srow = [src_tabs[sm[int(c)][0]][pos[sm[int(c)][0]][sm[int(c)][1]]] for c in rr["case_id"]]
    sser = np.array([pb.Series.Name(int(r["series"])) for r in srow])
    ok = rr["status"] == 0
    _STRICT["v"] = rr["resid_rel_final"] <= REL_TOL
    out = dict(total=frac(np.ones(len(rr), bool), ok), diverged=int((rr["status"] == 2).sum()),
               iters_conv_median=float(np.median(rr["iters"][ok])) if ok.any() else None,
               iters_conv_p90=float(np.percentile(rr["iters"][ok], 90)) if ok.any() else None,
               by_series={s: frac(sser == s, ok) for s in sorted(set(sser))})
    by = {}
    for s in sorted(set(sser)):
        m0 = sser == s
        d = {}
        for fac, vals in (("H", rr["heat_flux_wm2"]), ("h_over_zi", rr["h_over_zi"]), ("shape", rr["shape"]),
                          ("variant", rr["variant"]), ("h_m", rr["h_m"]), ("n_bv", np.round(rr["n_bv"], 4))):
            v = np.array([dec(x) if not isinstance(x, (float, np.floating)) else round(float(x), 4) for x in vals])
            u = sorted(set(v[m0].tolist()), key=str)
            if 1 < len(u) <= 40:
                d[fac] = {str(x): frac(m0 & (v == x), ok) for x in u}
        fr = rr["fr"].astype(float)
        bins = [0, 0.2, 0.3, 0.45, 0.6, 0.8, 1.0, 1.5, 2.5, 10]
        d["fr_bins"] = {f"{bins[i]}-{bins[i + 1]}": frac(m0 & (fr > bins[i]) & (fr <= bins[i + 1]), ok)
                        for i in range(len(bins) - 1) if (m0 & (fr > bins[i]) & (fr <= bins[i + 1])).any()}
        by[s] = d
    out["by_factor"] = by
    # GRID: по точкам Fr и H — доля сошедшихся во всей сетке до и после (81 линия × 30 Fr)
    return out, sser


def half_fr(fr, frac):
    """Наименьшее Fr, начиная с которого доля сошедшихся ≥ 0,5 во всех точках выше (граница сходимости по сетке)."""
    fr, frac = np.asarray(fr), np.asarray(frac)
    for i in range(len(fr)):
        if np.all(frac[i:] >= 0.5):
            return float(fr[i])
    return None


def grid_conv_curve(before, after):
    g = before["series"] == ap8.GRID
    out = {}
    for H in (0.0, 100.0, 250.0):
        m = g & (before["heat_flux_wm2"] == H)
        frs = np.unique(before["fr"][m])
        out[str(H)] = dict(fr=[round(float(f), 4) for f in frs],
                           before=[round(float((before["status"][m & (before["fr"] == f)] == 0).mean()), 3) for f in frs],
                           after=[round(float((after["status"][m & (after["fr"] == f)] == 0).mean()), 3) for f in frs])
        out[str(H)]["fr_half_before"] = half_fr(frs, out[str(H)]["before"])
        out[str(H)]["fr_half_after"] = half_fr(frs, out[str(H)]["after"])
    return out


# ------------------------------------------------------------------ 3. поле: позднее среднее против неподвижной точки
def _idx(d):
    idx = {}
    for p in sorted(Path(d).glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            for r, cid in enumerate(h["cases"]["case_id"][:]):
                idx[int(cid)] = (str(p), r)
    return idx


_F = {}


def _field(path, row):
    fs = _F.setdefault("files", {})
    if path not in fs:
        if len(fs) >= 16:
            fs.pop(next(iter(fs))).close()
        fs[path] = h5py.File(path, "r")
    return np.asarray(fs[path]["fields/f"][row], np.float32)


def _pair_job(job):
    out = []
    for (a, pa, ra, pb_, rb, us) in job:
        fa, fb = _field(pa, ra), _field(pb_, rb)
        sl = (slice(None), slice(EDGE, -EDGE), slice(EDGE, -EDGE))
        du = np.hypot(fa[0][sl] - fb[0][sl], fa[1][sl] - fb[1][sl])
        low = du[:9]
        out.append((a, float(np.percentile(low, 90) / us), float(np.percentile(low, 99) / us), float(du.max() / us),
                    float(np.percentile(du[1], 90)), float((low > 0.1 * us).mean())))
    return out


def stage_fields(rr, sm, workers):
    ok = np.nonzero(rr["status"] == 0)[0]
    ridx = _idx(rr_results())
    sidx = {k: _idx(v) for k, v in SRC.items()}
    jobs = []
    for q in ok:
        cid = int(rr["case_id"][q])
        sp, scid = sm[cid]
        if scid not in sidx[sp]:
            continue
        jobs.append((cid, *sidx[sp][scid], *ridx[cid], max(float(rr["u_sat"][q]), 1e-3)))
    jobs.sort(key=lambda j: (j[1], j[2]))
    chunks = [jobs[i:i + 40] for i in range(0, len(jobs), 40)]
    res = []
    with mp.get_context("fork").Pool(workers) as pool:
        for got in pool.imap_unordered(_pair_job, chunks):
            res.extend(got)
    res.sort()
    arr = np.array(res, dtype=[("case_id", "i8"), ("du_p90_rel", "f4"), ("du_p99_rel", "f4"), ("du_max_rel", "f4"),
                               ("du50_p90_ms", "f4"), ("area_gt01", "f4")])
    OUT.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(OUT / "late_vs_fixed.npz", pairs=arr)
    return arr


def late_vs_fixed(rr, sm, src_tabs, sser, arr):
    pos = {int(c): q for q, c in enumerate(rr["case_id"])}
    spos = {k: {int(c): q for q, c in enumerate(t["case_id"])} for k, t in src_tabs.items()}
    q = np.array([pos[int(c)] for c in arr["case_id"]])
    srow = [src_tabs[sm[int(c)][0]][spos[sm[int(c)][0]][sm[int(c)][1]]] for c in arr["case_id"]]
    spread = np.array([float(r["late_spread60_p90"]) for r in srow])
    ser = sser[q]
    out = {}
    for s in ["all"] + sorted(set(ser)):
        m = np.ones(len(arr), bool) if s == "all" else ser == s
        if m.sum() < 3:
            continue
        out[s] = dict(n=int(m.sum()),
                      du_p90_rel_median=round(float(np.median(arr["du_p90_rel"][m])), 4),
                      du_p99_rel_median=round(float(np.median(arr["du_p99_rel"][m])), 4),
                      du_p99_rel_p90=round(float(np.percentile(arr["du_p99_rel"][m], 90)), 4),
                      du_max_rel_median=round(float(np.median(arr["du_max_rel"][m])), 4),
                      frac_p99_gt01=round(float((arr["du_p99_rel"][m] > 0.1).mean()), 3),
                      du50_p90_over_spread_median=round(float(np.median(arr["du50_p90_ms"][m] / np.maximum(spread[m], 1e-6))), 3),
                      frac_inside_spread=round(float((arr["du50_p90_ms"][m] <= spread[m]).mean()), 3))
    # слои: layer_diff (позднее среднее − неподвижная точка), ключи и минимумы AP-8
    keys = ap8.LAYER_DIFF_KEYS
    ld = {k: [] for k in keys}
    lser = []
    for j, (c, r) in enumerate(zip(arr["case_id"], srow)):
        a = {k: float(r[k]) for k in keys}
        b = {k: float(rr[k][pos[int(c)]]) for k in keys}
        d = layer_diff(a, b)
        for k in keys:
            ld[k].append(d.get(k, np.nan))
        lser.append(ser[j])
    lser = np.array(lser)
    lay = {}
    for k in keys:
        v = np.array(ld[k], float)
        H = np.array([float(r["heat_flux_wm2"]) for r in srow])
        use = np.isfinite(v)
        if k.startswith("th_"):
            use &= H > 0
        if use.sum() < 3:
            continue
        lay[k] = dict(n=int(use.sum()), min_dy=ap8.LAYER_DIFF_MIN[k], abs_median=round(float(np.median(np.abs(v[use]))), 4),
                      mean=round(float(np.mean(v[use])), 4), frac_ge_min=round(float((np.abs(v[use]) >= ap8.LAYER_DIFF_MIN[k]).mean()), 3),
                      by_series={s: round(float((np.abs(v[use & (lser == s)]) >= ap8.LAYER_DIFF_MIN[k]).mean()), 3)
                                 for s in sorted(set(lser[use])) if (use & (lser == s)).sum() >= 5})
    return out, lay, spread


# ------------------------------------------------------------------ 4. подгонки AP-8 до/после
def stage_fits_grid(t, D, workers, n_boot, ok, base):
    """Как ap8.stage_fits, но только линии GRID (меняются только они: SWEEP не пересчитывался); подгонки SWEEP и
    gridwin (гистерезис) — из `base` (до пересчёта), шум стартов — заново (статусы GRID изменились)."""
    per, glob = ap8.start_noise(t, D, ok)
    params = {p: v for p, v in ap8.PARAMS.items() if not (ok and p in ("conv", "spread_rel"))}
    g = t["series"] == ap8.GRID
    if ok:
        g = g & (t["status"] == 0)
    jobs = []
    for L in np.unique(t["line_id"][t["series"] == ap8.GRID]):
        m = g & (t["line_id"] == L)
        r0 = t[(t["series"] == ap8.GRID) & (t["line_id"] == L)][0]
        for p, (_, kind, _, _) in params.items():
            if ap8.line_ok(kind, float(r0["heat_flux_wm2"])):
                jobs.append((("grid", int(L), p), t["fr"][m], D[p][m], per.get((int(L), p), glob[p]), n_boot, "grid"))
    pre = "ok:" if ok else ""
    fits = {k: v for k, v in base.items() if not k.startswith(pre + "grid|")}
    with mp.get_context("fork").Pool(workers) as pool:
        for key, r in pool.imap_unordered(ap8._fit_job, jobs, chunksize=4):
            fits[pre + "|".join(map(str, key))] = r
    noise = {"per_line": {f"{L}|{p}": v for (L, p), v in per.items()}, "global": glob}
    (ap8.OUT / ("fits_ok.json" if ok else "fits.json")).write_text(json.dumps({"fits": fits, "noise": noise}, ensure_ascii=False))
    return fits, noise


def fits_for(tab, tag, workers, n_boot, redo, base=None):
    """base — каталог «до»: тогда пересчитываются только подгонки GRID (stage_fits_grid)."""
    d = OUT / tag
    d.mkdir(parents=True, exist_ok=True)
    ap8.OUT, ap8.HERE = d, d
    D = ap8.derived(tab)
    if redo or not (d / "fits.json").exists():
        if base is not None:
            fits, noise = stage_fits_grid(tab, D, workers, n_boot, False, json.loads((base / "fits.json").read_text())["fits"])
        else:
            fits, noise = ap8.stage_fits(tab, D, workers, n_boot)
    else:
        j = json.loads((d / "fits.json").read_text()); fits, noise = j["fits"], j["noise"]
    if redo or not (d / "fits_ok.json").exists():
        if base is not None:
            fo, no = stage_fits_grid(tab, D, workers, n_boot, True, json.loads((base / "fits_ok.json").read_text())["fits"])
        else:
            fo, no = ap8.stage_fits(tab, D, workers, n_boot, ok=True)
    else:
        j = json.loads((d / "fits_ok.json").read_text()); fo, no = j["fits"], j["noise"]
    fits.update(fo)
    noise = dict(noise, global_ok=no["global"])
    pairs = np.load(HERE.parent / "AP-8" / "pairs.npz")["pairs"]
    s = ap8.stage_report(tab, D, fits, noise, pairs)       # summary.json и рисунки AP-8 — в out/AP-14/<tag>/
    return s


def compare_bounds(sb, sa):
    kb = {(b["line_id"], b["param"]): b for b in sb["boundaries"]}
    ka = {(b["line_id"], b["param"]): b for b in sa["boundaries"]}
    both = sorted(set(kb) & set(ka))
    per = {}
    for p in ap8.PARAMS:
        bb = [k for k in both if k[1] == p]
        lost = [k for k in kb if k[1] == p and k not in ka]
        new = [k for k in ka if k[1] == p and k not in kb]
        if not (bb or lost or new):
            continue
        dl = np.array([np.log10(ka[k]["fr_c"] / kb[k]["fr_c"]) for k in bb])
        dw = np.array([ka[k]["w_dec"] - kb[k]["w_dec"] for k in bb])
        moved = [k for k, x in zip(bb, dl) if abs(x) > max(2 * kb[k]["w_dec"], 2 * ka[k]["w_dec"], kb[k]["step_dec"] or 0)]
        ag_b, ag_a = sb["aggregate"].get(p, {}), sa["aggregate"].get(p, {})
        per[p] = dict(n_before=sum(1 for k in kb if k[1] == p), n_after=sum(1 for k in ka if k[1] == p), n_both=len(bb),
                      n_lost=len(lost), n_new=len(new),
                      dlog_frc_median=round(float(np.median(dl)), 4) if bb else None,
                      dlog_frc_abs_p90=round(float(np.percentile(np.abs(dl), 90)), 4) if bb else None,
                      dw_median=round(float(np.median(dw)), 4) if bb else None,
                      n_moved_gt_2w=len(moved),
                      n_class_changed=sum(1 for k in bb if ka[k]["cls"] != kb[k]["cls"]),
                      n_in_gap_before=ag_b.get("n_in_gap"), n_in_gap_after=ag_a.get("n_in_gap"),
                      n_sharp_before=ag_b.get("n_sharp"), n_sharp_after=ag_a.get("n_sharp"),
                      clean_before={k: ag_b.get("clean", {}).get(k) for k in ("n", "fr_c_median", "fr_c_p25_p75", "w_dec_median", "n_sharp")},
                      clean_after={k: ag_a.get("clean", {}).get(k) for k in ("n", "fr_c_median", "fr_c_p25_p75", "w_dec_median", "n_sharp")},
                      moved=[dict(line_id=k[0], shape=kb[k]["shape"], s=kb[k]["s"], H=kb[k]["H"], h_over_zi=kb[k]["h_over_zi"],
                                  fr_c=[kb[k]["fr_c"], ka[k]["fr_c"]], w=[kb[k]["w_dec"], ka[k]["w_dec"]],
                                  cls=[kb[k]["cls"], ka[k]["cls"]]) for k in moved][:12],
                      new=[dict(line_id=k[0], shape=ka[k]["shape"], H=ka[k]["H"], h_over_zi=ka[k]["h_over_zi"],
                                fr_c=ka[k]["fr_c"], w=ka[k]["w_dec"], cls=ka[k]["cls"]) for k in new][:12])
    # переходная полоса Fr 0,45–1,0: границы до/после; судьба границ «в пропуске» сетки (до)
    band = {}
    for p in ap8.PARAMS:
        fb = [b["fr_c"] for b in sb["boundaries"] if b["param"] == p and 0.45 < b["fr_c"] <= 1.0]
        fa = [b["fr_c"] for b in sa["boundaries"] if b["param"] == p and 0.45 < b["fr_c"] <= 1.0]
        if fb or fa:
            band[p] = dict(n_before=len(fb), n_after=len(fa),
                           fr_c_median_before=round(float(np.median(fb)), 3) if fb else None,
                           fr_c_median_after=round(float(np.median(fa)), 3) if fa else None)
    gap = [dict(param=k[1], line_id=k[0], shape=kb[k]["shape"], H=kb[k]["H"], h_over_zi=kb[k]["h_over_zi"],
                fr_c_before=kb[k]["fr_c"], fr_c_after=ka[k]["fr_c"] if k in ka else None,
                in_gap_after=ka[k]["in_gap"] if k in ka else None, w_after=ka[k]["w_dec"] if k in ka else None)
           for k in kb if kb[k]["in_gap"]]
    calm_new = {p: sum(1 for k in ka if k[1] == p and k not in kb and ka[k]["calm"]) for p in ap8.PARAMS}
    tot = dict(band_045_10=band, in_gap_fate=gap, new_calm_by_param={p: v for p, v in calm_new.items() if v},
               n_new_calm=sum(calm_new.values()),
               n_new_not_calm=sum(1 for k in ka if k not in kb and not ka[k]["calm"]),
               n_before=len(kb), n_after=len(ka), n_both=len(both),
               n_sharp_w_before=sum(b["w_dec"] < 0.1 for b in sb["boundaries"]),
               n_sharp_w_after=sum(b["w_dec"] < 0.1 for b in sa["boundaries"]),
               n_in_gap_before=sum(b["in_gap"] for b in sb["boundaries"]),
               n_in_gap_after=sum(b["in_gap"] for b in sa["boundaries"]))
    return tot, per


def fmt(v, nd=2):
    if v is None:
        return "—"
    return f"{v:.{nd}f}".replace(".", ",")


def tables_md(per, conv, lvf, lay):
    """tables.md: границы AP-8 до/после по параметрам (чистые — не штиль и не в пропуске), сходимость, слои."""
    L = ["# AP-14: таблицы (генерирует run.py)", "",
         "## Границы AP-8 до и после пересчёта (GRID; «чистые» — Fr_c > 0,45 и не в пропуске сетки)", "",
         "| параметр | линий: все до→после (чистые до→после) | Fr_c чистых до → после (25–75 % после) | w, дек до → после | "
         "резких чистых до→после | общих | медиана Δlg Fr_c | сдвиг > 2w | смена класса | в пропуске до→после |",
         "|---|---|---|---|---|---|---|---|---|---|"]
    for p in ap8.PARAMS:
        v = per.get(p)
        if not v:
            continue
        cb, ca = v["clean_before"], v["clean_after"]
        iq = ca.get("fr_c_p25_p75") or [None, None]
        L.append(f"| {p} | {v['n_before']}→{v['n_after']} ({cb.get('n') or 0}→{ca.get('n') or 0}) | "
                 f"{fmt(cb.get('fr_c_median'))} → {fmt(ca.get('fr_c_median'))} ({fmt(iq[0])}–{fmt(iq[1])}) | "
                 f"{fmt(cb.get('w_dec_median'), 3)} → {fmt(ca.get('w_dec_median'), 3)} | {cb.get('n_sharp') or 0}→{ca.get('n_sharp') or 0} | "
                 f"{v['n_both']} | {fmt(v['dlog_frc_median'], 3)} | {v['n_moved_gt_2w']} | {v['n_class_changed']} | "
                 f"{v['n_in_gap_before']}→{v['n_in_gap_after']} |")
    L += ["", "## Сходимость пересчёта по исходной серии (ω = 0,5, 2000 итераций, холодный старт)", "",
          "| серия | случаев | сошлось | доля | доля со строгим относительным критерием |", "|---|---|---|---|---|"]
    for s_, d in conv["by_series"].items():
        L.append(f"| {s_} | {d['n']} | {d['conv']} | {fmt(d['frac'], 3)} | {fmt(d.get('frac_rel_strict'), 3)} |")
    t = conv["total"]
    L.append(f"| всего | {t['n']} | {t['conv']} | {fmt(t['frac'], 3)} | {fmt(t.get('frac_rel_strict'), 3)} |")
    for s_, d in conv["by_factor"].items():
        L += ["", f"### {s_}: по факторам", "", "| фактор | значение | случаев | доля сошедшихся |", "|---|---|---|---|"]
        for fac, dd in d.items():
            for k, x in dd.items():
                if not x["n"]:
                    continue
                L.append(f"| {fac} | {k} | {x['n']} | {fmt(x['frac'], 3)} |")
    L += ["", "## Позднее среднее (ω = 1) против неподвижной точки (сошедшиеся после пересчёта)", "",
          r"| серия | случаев | p99 \|Δu_h\| / U, медиана | p99 / U, 90 % | доля p99 > 0,1 U | p90 на 50 м / разброс, медиана | внутри разброса |",
          "|---|---|---|---|---|---|---|"]
    for s_, d in lvf.items():
        L.append(f"| {s_} | {d['n']} | {fmt(d['du_p99_rel_median'], 3)} | {fmt(d['du_p99_rel_p90'], 3)} | {fmt(d['frac_p99_gt01'], 3)} | "
                 f"{fmt(d['du50_p90_over_spread_median'], 2)} | {fmt(d['frac_inside_spread'], 3)} |")
    L += ["", r"| метрика слоя | случаев | физ. минимум | медиана \|Δ\| | доля \|Δ\| ≥ минимума |", "|---|---|---|---|---|"]
    for k, d in lay.items():
        L.append(f"| {k} | {d['n']} | {fmt(d['min_dy'], 1)} | {fmt(d['abs_median'], 3)} | {fmt(d['frac_ge_min'], 3)} |")
    (HERE / "tables.md").write_text("\n".join(L) + "\n")


# ------------------------------------------------------------------ рисунки
def figures(curve, arr, spread, cmp_per, lay):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.size": 9})
    fig, axs = plt.subplots(1, 3, figsize=(12, 3.6), sharey=True)
    for ax, (H, c) in zip(axs, curve.items()):
        ax.semilogx(c["fr"], c["before"], "o-", ms=3, label="ω = 1, 1000 итераций")
        ax.semilogx(c["fr"], c["after"], "s-", ms=3, label="+ пересчёт ω = 0,5, 2000")
        ax.set_title(f"GRID, H = {float(H):.0f} Вт/м²"); ax.set_xlabel("Fr"); ax.grid(alpha=0.3)
    axs[0].set_ylabel("доля сошедшихся (27 линий)"); axs[0].legend(fontsize=8)
    fig.tight_layout(); fig.savefig(HERE / "fig_conv_by_fr.png", dpi=110); plt.close(fig)

    fig, axs = plt.subplots(1, 2, figsize=(10, 3.8))
    axs[0].hist(np.log10(np.maximum(arr["du_p99_rel"], 1e-4)), bins=40)
    axs[0].axvline(-1, color="k", ls="--", lw=0.8)
    axs[0].set_xlabel("lg p99 |Δu_h| ≤ 600 м / U_sat (позднее среднее − неподвижная точка)"); axs[0].set_ylabel("случаев")
    axs[1].loglog(np.maximum(spread, 1e-4), np.maximum(arr["du50_p90_ms"], 1e-4), ".", ms=2)
    lim = [1e-3, 10]
    axs[1].plot(lim, lim, "k--", lw=0.8)
    axs[1].set_xlabel("разброс поздних итераций p90, м/с (исходный)"); axs[1].set_ylabel("p90 |Δu_h| на 50 м, м/с")
    fig.tight_layout(); fig.savefig(HERE / "fig_late_vs_fixed.png", dpi=110); plt.close(fig)

    ps = [p for p, v in cmp_per.items() if v["n_both"]]
    if ps:
        fig, ax = plt.subplots(figsize=(10, 3.8))
        for i, p in enumerate(ps):
            v = cmp_per[p]
            ax.bar(i - 0.2, v["n_before"], 0.4, color="#9ecae1")
            ax.bar(i + 0.2, v["n_after"], 0.4, color="#3182bd")
            ax.text(i, max(v["n_before"], v["n_after"]) + 0.5, f"{v['dlog_frc_median']:+.3f}", ha="center", fontsize=7)
        ax.set_xticks(range(len(ps))); ax.set_xticklabels(ps, rotation=60, ha="right", fontsize=7)
        ax.set_ylabel("принятых границ (до / после)"); ax.set_title("число границ и медиана Δlg Fr_c (подпись)")
        fig.tight_layout(); fig.savefig(HERE / "fig_bounds_before_after.png", dpi=110); plt.close(fig)

    if lay:
        ks = list(lay)
        fig, ax = plt.subplots(figsize=(8, 3.4))
        ax.barh(range(len(ks)), [lay[k]["frac_ge_min"] for k in ks])
        ax.set_yticks(range(len(ks))); ax.set_yticklabels(ks, fontsize=7)
        ax.set_xlabel("доля случаев с |Δ| ≥ физического минимума (позднее среднее − неподвижная точка)")
        fig.tight_layout(); fig.savefig(HERE / "fig_layers.png", dpi=110); plt.close(fig)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--workers", type=int, default=max(1, min(16, (os.cpu_count() or 2) - 2)))
    ap.add_argument("--n-boot", type=int, default=200)
    ap.add_argument("--stage", default="all", choices=["all", "before", "merge", "fields", "fits", "report"])
    a = ap.parse_args(argv)
    t0 = time.time()
    v1, v2 = load("ap_v1"), load("ap_v2")
    if a.stage == "before":                               # подгонки по исходной таблице — можно до пересчёта
        fits_for(v1, "before", a.workers, a.n_boot, True)
        return
    rr = load("ap_v1r")
    sm = src_map()
    m1, n1 = merge(v1, rr, "ap_v1", sm)
    m2, n2 = merge(v2, rr, "ap_v2", sm)
    p1, p2 = write_merged(m1, "ap_v1"), write_merged(m2, "ap_v2")
    print(f"объединение: ap_v1 заменено {n1}, ap_v2 {n2} → {p1}, {p2}", flush=True)
    if a.stage == "merge":
        return
    conv, sser = convergence(rr, sm, {"ap_v1": v1, "ap_v2": v2})
    if a.stage in ("all", "fields") or not (OUT / "late_vs_fixed.npz").exists():
        arr = stage_fields(rr, sm, a.workers)
    else:
        arr = np.load(OUT / "late_vs_fixed.npz")["pairs"]
    lvf, lay, spread = late_vs_fixed(rr, sm, {"ap_v1": v1, "ap_v2": v2}, sser, arr)
    if a.stage == "fields":
        return
    redo = a.stage in ("all", "fits")
    sb = fits_for(v1, "before", a.workers, a.n_boot, redo and not (OUT / "before" / "fits_ok.json").exists())
    sa = fits_for(m1, "after", a.workers, a.n_boot, redo, base=OUT / "before")
    tot, per = compare_bounds(sb, sa)
    curve = grid_conv_curve(v1, m1)
    g = v1["series"] == ap8.GRID
    summary = dict(
        task="AP-14", inputs=dict(rerun_plan=str(RR_PLAN), rerun_results=str(rr_results()), sources={k: str(v) for k, v in SRC.items()},
                                  merged=[str(p1), str(p2)]),
        rule="объединение: исходный случай, если сошёлся, иначе пересчёт (ω = 0,5, 2000 итераций, холодный старт)",
        n_rerun=int(len(rr)), n_replaced=dict(ap_v1=n1, ap_v2=n2),
        convergence=conv,
        grid_conv_frac=dict(before=round(float((v1["status"][g] == 0).mean()), 3), after=round(float((m1["status"][g] == 0).mean()), 3)),
        grid_conv_curve=curve,
        late_vs_fixed=dict(fields=lvf, layers=lay,
                           note="случаи, сошедшиеся после пересчёта: исходное позднее среднее (ω = 1) против неподвижной точки"),
        bounds=dict(total=tot, per_param=per,
                    moved_criterion="|Δlg Fr_c| > max(2w до, 2w после, шаг сетки) — граница сдвинулась заметно"),
        conv_param_after=sa["aggregate"].get("conv"), conv_param_before=sb["aggregate"].get("conv"),
        seconds=round(time.time() - t0, 1))
    (HERE / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1, default=float))
    figures(curve, arr, spread, per, lay)
    tables_md(per, conv, lvf, lay)
    print(json.dumps(dict(total=conv["total"], grid=summary["grid_conv_frac"], bounds=tot), ensure_ascii=False))


if __name__ == "__main__":
    main()
