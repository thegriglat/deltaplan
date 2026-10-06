"""AP-8: границы фаз в GRID (параметры порядка §4.1 и метрики слоёв P6 против Fr), резкость, второй старт и
гистерезис (SWEEP против GRID). Только CPU, данные только читаются.

    PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
    $PY tools/research/air_phase/analysis/AP-8/run.py [--workers 16] [--n-boot 200] [--stage all|pairs|fits|report]

Вход: таблица признаков P6 `$AIR_SYNTH_DATA/phase/features_ap_v1.h5`, поля P3 `$AIR_SYNTH_DATA/phase/ap_v1__s1-74644c4/`.
Выход (P7): `summary.json`, `fig_*.png` рядом; промежуточные `pairs.npz` (расхождения полей пар, ~0,3 МБ) и
`out/AP-8/fits.json` (все подгонки, кэш).

Что считается:
1. GRID (81 линия × 30 Fr): для каждого параметра y(Fr) — `sigmoid.fit_sigmoid` (P6): порог Fr_c (бутстрэп-ДИ), ширина
   w (декады), класс резкая/плавная (§9 п. 6). Шум для критерия «скачок > 3σ» — разброс того же y между стартами
   (SWEEP тёплый против GRID холодного, та же точка, одинаковый статус сходимости; 1,4826·MAD по линии).
   Граница засчитывается, если x_c и ДИ внутри диапазона Fr, |Δy| ≥ физического минимума параметра (MIN_DY), R² ≥ 0,5,
   w ≤ 1 декады. w меньше местного шага сетки Fr — «не разрешена сеткой» (резкая, w — верхняя оценка = шаг).
2. SWEEP (162 линии: вверх/вниз по Fr 0,3–1,3, тёплый старт от соседа): пары (тёплый, холодный GRID) и (вверх, вниз)
   в той же точке — расхождение полей |Δu_h|/U_sat (§9 п. 3: > 0,1 при одинаковой сходимости — две ветви), разности
   метрик слоёв (`layer_diff`) и IoU карт; несошедшиеся — сравнение с разбросом поздних итераций (та же область
   блуждания или другая). Гистерезис — подгонка y(Fr) отдельно на проходах вверх и вниз: |lg Fr_c↑ − lg Fr_c↓| > 2w.
"""
from __future__ import annotations

import argparse
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
from sigmoid import fit_sigmoid  # noqa: E402
from layer_metrics import layer_diff  # noqa: E402

DATA = Path(os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data"))) / "phase"
FEAT = DATA / "features_ap_v1.h5"
RES = DATA / "ap_v1__s1-74644c4"
OUT = AP / "out" / "AP-8"
EDGE = 5
GRID, SWEEP = 1, 2
BRANCH_DU = 0.1          # §9 п. 3: расхождение полей > 0,1 U_sat — две ветви
GAP_DEC = 0.13           # шаг между соседними использованными точками > 0,13 дек — порог «в разрыве» (у сошедшихся —
                         # пропуск полосы несходимости; естественный шаг сетки ≤ 0,125 дек)
CALM_FR = 0.45           # в GRID Fr ≤ 0,45 — U10 < 1 м/с (штиль, фаза H)

# параметр → (группа, какие линии, физический минимум |Δy|, описание)
# lines: all — все 81; heat — только H > 0 (термики при H = 0 не существуют); mech — только H = 0 (sl_* считаются
# по w_mech близнеца H = 0 — у H > 0 те же числа)
PARAMS = {
    "conv":              ("pic", "all", 0.5, "сходимость Пикара (1 — сошёлся), §4.2"),
    "spread_rel":        ("pic", "all", 0.05, "разброс поздних итераций late_spread60_p90 / U_sat"),
    "f_stag25":          ("order", "all", 0.02, "застой: доля |u_h| < 0,3 U_b на 25 м (D)"),
    "f_turn25":          ("order", "all", 0.02, "обход: доля поворота > 45° на 25 м (D)"),
    "f_rev25":           ("order", "all", 0.02, "обратное течение: доля u·e < −0,05 U_b на 25 м (B, D)"),
    "f_speed50":         ("order", "all", 0.1, "средняя |u_h|/U_b на 50 м (A, D)"),
    "wstd600_rel":       ("order", "all", 0.02, "σ_w на 600 м / U_sat (волны, C)"),
    "f_wskew300":        ("order", "all", 1.0, "асимметрия w на 300 м (термики, F)"),
    "th_src_density_km2": ("th", "heat", 0.5, "источников термиков на км²"),
    "th_src_relief_ratio": ("th", "heat", 0.2, "густота источников на рельефе / вне (привязка к рельефу)"),
    "th_src_x_mean_over_h": ("th", "heat", 1.0, "смещение источников по ветру от вершины, доли h"),
    "th_w0_mean_ms":     ("th", "heat", 0.2, "сила ядра w0, м/с"),
    "th_ceil_over_zi":   ("th", "heat", 0.3, "потолок частицы / z_i"),
    "th_org_frac":       ("th", "heat", 0.1, "доля организованного подъёма в потоке водосборов"),
    "drift_rel":         ("th", "all", 0.1, "снос: средний ветер 0..z_i / U_sat"),
    "sl_area_km2":       ("sl", "mech", 4.0, "площадь подъёма > 1 м/с у наветренного склона, км²"),
    "sl_w_max_over_us":  ("sl", "mech", 0.1, "max w у склона / (U_sat·s)"),
    "sl_ceil_agl_m":     ("sl", "mech", 200.0, "потолок подъёма ≥ 1 м/с над склоном, м"),
    "lee_area25_km2":    ("lee", "all", 4.0, "площадь подветренной зоны (признак ≥ ½, 25 м), км²"),
    "lee_depth_max_m":   ("lee", "all", 100.0, "глубина подветренной зоны, м"),
    "lee_rev_area25_km2": ("lee", "all", 4.0, "площадь разрешённого обратного течения (25 м), км²"),
    "lee_urev_min_over_us": ("lee", "all", 0.1, "min u·e у земли / U_sat (ротор)"),
    "lee_desc_max":      ("lee", "all", 0.03, "наклон опускания s_d за вершиной"),
    "lee_du_rel":        ("lee", "all", 0.1, "скачок слоя смешения ΔU_max / U_sat"),
}
LAYER_DIFF_KEYS = ["th_src_density_km2", "th_w0_mean_ms", "th_ceil_over_zi", "th_src_x_mean_over_h",
                   "sl_area_km2", "sl_w_max_ms", "lee_area25_km2", "lee_depth_max_m", "lee_rev_area25_km2",
                   "lee_du_max_ms"]
LAYER_DIFF_MIN = {"th_src_density_km2": 0.5, "th_w0_mean_ms": 0.2, "th_ceil_over_zi": 0.3, "th_src_x_mean_over_h": 1.0,
                  "sl_area_km2": 4.0, "sl_w_max_ms": 0.3, "lee_area25_km2": 4.0, "lee_depth_max_m": 100.0,
                  "lee_rev_area25_km2": 4.0, "lee_du_max_ms": 0.5}


def dec(v):
    return v.decode() if isinstance(v, (bytes, np.bytes_)) else v


def load_table():
    with h5py.File(FEAT, "r") as h:
        t = h["features"][:]
    return t


def derived(t):
    """Колонки PARAMS из таблицы (производные — нормировки на U_sat)."""
    us = np.maximum(t["u_sat"].astype(float), 1e-3)
    d = {"conv": (t["status"] == 0).astype(float), "spread_rel": t["late_spread60_p90"] / us,
         "wstd600_rel": t["f_wstd600"] / us, "drift_rel": t["th_drift_zi_ms"] / us,
         "lee_du_rel": t["lee_du_max_ms"] / us}
    for k in PARAMS:
        if k not in d:
            d[k] = t[k].astype(float)
    return d


def cfg_of(r):
    return (dec(r["shape"]), round(float(r["slope"]), 3), round(float(r["heat_flux_wm2"]), 1), round(float(r["h_over_zi"]), 3))


# ------------------------------------------------------------------ 1. пары полей
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
    for (a, pa, ra, b, pb, rb, us) in job:
        fa, fb = _field(pa, ra), _field(pb, rb)
        sl = (slice(None), slice(EDGE, -EDGE), slice(EDGE, -EDGE))
        du = np.hypot(fa[0][sl] - fb[0][sl], fa[1][sl] - fb[1][sl])          # (13, ny, nx), м/с
        dw = np.abs(fa[2][sl] - fb[2][sl])
        low = du[:9]                                                          # ≤ 600 м
        out.append((a, b, float(du.max() / us), float(np.percentile(low, 99) / us), float(np.percentile(low, 90) / us),
                    float(np.percentile(du[1], 90)), float(dw.max() / us), float((low > BRANCH_DU * us).mean())))
    return out


def stage_pairs(t, workers):
    idx = {}
    for p in sorted(RES.glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            for r, cid in enumerate(h["cases"]["case_id"][:]):
                idx[int(cid)] = (str(p), r)
    s = t[t["series"] == SWEEP]
    pairs = []      # (a, b, kind) kind 0: тёплый/холодный SWEEP против GRID, 1: вверх против вниз
    by_ref = {}
    for r in s:
        if r["ref_case_id"] >= 0:
            pairs.append((int(r["case_id"]), int(r["ref_case_id"]), 0))
            by_ref.setdefault(int(r["ref_case_id"]), {})[dec(r["variant"])] = int(r["case_id"])
    for ref, d in by_ref.items():
        if "up" in d and "down" in d:
            pairs.append((d["up"], d["down"], 1))
    us = dict(zip(t["case_id"].tolist(), t["u_sat"].astype(float).tolist()))
    jobs = [(a, *idx[a], b, *idx[b], max(us[a], 1e-3)) for a, b, _ in pairs]
    jobs.sort(key=lambda j: (j[1], j[2]))
    chunks = [jobs[i:i + 40] for i in range(0, len(jobs), 40)]
    t0 = time.time()
    res = []
    with mp.get_context("fork").Pool(workers) as pool:
        for got in pool.imap_unordered(_pair_job, chunks):
            res.extend(got)
    kind = {(a, b): k for a, b, k in pairs}
    res.sort()
    arr = np.array([(a, b, kind[(a, b)], *v) for a, b, *v in res],
                   dtype=[("a", "i8"), ("b", "i8"), ("kind", "i1"), ("du_max_rel", "f4"), ("du_p99_rel", "f4"),
                          ("du_p90_rel", "f4"), ("du50_p90_ms", "f4"), ("dw_max_rel", "f4"), ("area_gt01", "f4")])
    np.savez_compressed(HERE / "pairs.npz", pairs=arr)
    print(f"пары: {len(arr)} за {time.time() - t0:.0f} с", flush=True)
    return arr


# ------------------------------------------------------------------ 2. подгонки
def local_step(fr_pts, xc):
    """Местный шаг сетки Fr в декадах около x_c (разрешение ширины)."""
    lx = np.log10(np.unique(fr_pts))
    if not np.isfinite(xc) or xc <= 0:
        return float("nan")
    k = np.searchsorted(lx, np.log10(xc))
    k = int(np.clip(k, 1, lx.size - 1))
    return float(lx[k] - lx[k - 1])


def _fit_job(job):
    key, x, y, noise, n_boot, frange = job
    r = fit_sigmoid(x, y, n_boot=n_boot, noise=noise)
    r = {k: (list(v) if isinstance(v, tuple) else v) for k, v in r.items()}
    yy = np.asarray(y, float)
    m = np.isfinite(yy)
    var = float(np.var(yy[m])) if m.sum() > 1 else 0.0
    r["r2"] = float(1 - r["resid_std"] ** 2 / var) if var > 0 and np.isfinite(r["resid_std"]) else float("nan")
    r["step_dec"] = local_step(np.asarray(x)[m], r["x_c"])
    r["noise"] = None if noise is None else float(noise)
    r["frange"] = frange
    return key, r


def robust_sigma(d):
    d = np.asarray(d, float)
    d = d[np.isfinite(d)]
    if d.size < 3:
        return None
    return float(1.4826 * np.median(np.abs(d - np.median(d))))


def start_noise(t, D, ok=False):
    """σ шума между стартами: по базовой линии GRID и параметру — 1,4826·MAD разностей (SWEEP тёплый − GRID) у пар с
    одинаковым статусом сходимости. Возвращает {(line_id_grid, param): σ} и глобальные {param: σ}."""
    pos = {c: i for i, c in enumerate(t["case_id"].tolist())}
    s = np.nonzero((t["series"] == SWEEP) & (t["start_case_id"] >= 0) & (t["ref_case_id"] >= 0))[0]
    ref = np.array([pos[c] for c in t["ref_case_id"][s]])
    same = t["status"][s] == t["status"][ref]
    if ok:
        same &= t["status"][s] == 0
    s, ref = s[same], ref[same]
    gl = t["line_id"][ref]
    per, glob = {}, {}
    for p in PARAMS:
        d = D[p][s] - D[p][ref]
        glob[p] = robust_sigma(d)
        for L in np.unique(gl):
            v = robust_sigma(d[gl == L])
            if v is not None:
                per[(int(L), p)] = v
    return per, glob


def line_ok(kind, H):
    return kind == "all" or (kind == "heat" and H > 0) or (kind == "mech" and H == 0)


def stage_fits(t, D, workers, n_boot, ok=False):
    """ok=True — только сошедшиеся точки (AP-13: несходимость без нагрева — отказ решателя, а не фаза); ключи 'ok:…',
    кэш fits_ok.json; conv и spread_rel в этом режиме не подгоняются."""
    per, glob = start_noise(t, D, ok)
    jobs = []
    params = {p: v for p, v in PARAMS.items() if not (ok and p in ("conv", "spread_rel"))}
    g = t["series"] == GRID
    if ok:
        g = g & (t["status"] == 0)
    for L in np.unique(t["line_id"][g]):
        m = g & (t["line_id"] == L)
        r0 = t[m][0]
        for p, (_, kind, _, _) in params.items():
            if not line_ok(kind, float(r0["heat_flux_wm2"])):
                continue
            nz = per.get((int(L), p), glob[p])
            jobs.append(((("grid", int(L), p)), t["fr"][m], D[p][m], nz, n_boot, "grid"))
    s = t["series"] == SWEEP
    s_all = s
    if ok:
        s = s & (t["status"] == 0)
    pos = {c: i for i, c in enumerate(t["case_id"].tolist())}
    for L in np.unique(t["line_id"][s_all]):
        m = s & (t["line_id"] == L)
        rr = t[s_all & (t["line_id"] == L)]
        refl = int(t["line_id"][pos[int(rr["ref_case_id"][0])]])
        for p, (_, kind, _, _) in params.items():
            if not line_ok(kind, float(rr[0]["heat_flux_wm2"])):
                continue
            nz = per.get((refl, p), glob[p])
            jobs.append(((dec(rr[0]["variant"]), int(L), p), t["fr"][m], D[p][m], nz, n_boot, "sweep"))
        # та же базовая линия GRID, обрезанная до диапазона SWEEP (холодный старт в том же окне)
        if dec(rr[0]["variant"]) == "up":
            mg = g & (t["line_id"] == refl) & (t["fr"] >= 0.299) & (t["fr"] <= 1.301)
            for p, (_, kind, _, _) in params.items():
                if line_ok(kind, float(rr[0]["heat_flux_wm2"])):
                    jobs.append((("gridwin", refl, p), t["fr"][mg], D[p][mg], per.get((refl, p), glob[p]), n_boot,
                                 "gridwin"))
    t0 = time.time()
    fits = {}
    with mp.get_context("fork").Pool(workers) as pool:
        for n, (key, r) in enumerate(pool.imap_unordered(_fit_job, jobs, chunksize=4)):
            fits[("ok:" if ok else "") + "|".join(map(str, key))] = r
            if (n + 1) % 500 == 0:
                print(f"подгонок {n + 1}/{len(jobs)}, {time.time() - t0:.0f} с", flush=True)
    OUT.mkdir(parents=True, exist_ok=True)
    noise = {"per_line": {f"{L}|{p}": v for (L, p), v in per.items()}, "global": glob}
    (OUT / ("fits_ok.json" if ok else "fits.json")).write_text(json.dumps({"fits": fits, "noise": noise}, ensure_ascii=False))
    print(f"подгонки: {len(fits)} за {time.time() - t0:.0f} с", flush=True)
    return fits, noise


# ------------------------------------------------------------------ 3. сводка
def pre(p):
    """Ключ основной подгонки: conv/spread_rel — по всем точкам (это свойство решателя), остальное — по сошедшимся."""
    return "" if p in ("conv", "spread_rel") else "ok:"


def accept(r, p, lo, hi):
    """Граница засчитывается? → (ok, причина)."""
    if not np.isfinite(r["x_c"]):
        return False, "fit_fail"
    ci = r["x_c_ci"]
    if not (lo <= r["x_c"] <= hi) or not (np.isfinite(ci[0]) and np.isfinite(ci[1])) or ci[0] < lo * 0.8 or ci[1] > hi * 1.25:
        return False, "out_of_range"
    if abs(r["dy"]) < PARAMS[p][2]:
        return False, "small_dy"
    if not (r["r2"] >= 0.5):
        return False, "poor_fit"
    if r["w_dec"] > 1.0:
        return False, "trend"
    return True, "ok"


def klass(r):
    """Класс §9 п. 6 с уточнением: «скачок > 3σ шума стартов» засчитывается как резкость, только если этот скачок
    несёт ≥ ½ всего перехода |Δy| (иначе любой тренд на сетке из 30 точек «резкий»: шум повторного старта у
    сошедшихся ~1e-3 доли U, а шаг тренда между соседями больше). Флаг sharp из fit_sigmoid сохраняется как sharp_p6."""
    jump_ok = (r["noise"] is not None and np.isfinite(r["jump_max"]) and r["jump_max"] > 3 * r["noise"]
               and r["jump_max"] >= 0.5 * abs(r["dy"]))
    if r["w_dec"] < 0.1 or jump_ok:
        return "sharp"
    return "smooth" if r["w_dec"] > 0.3 else "mid"


def interp_log(xq, x, y):
    o = np.argsort(x)
    x, y = np.asarray(x)[o], np.asarray(y, float)[o]
    m = y > 0
    if m.sum() < 2:
        return float("nan")
    return float(10 ** np.interp(np.log10(xq), np.log10(x[m]), np.log10(y[m])))


def stage_report(t, D, fits, noise, pairs):
    g = t["series"] == GRID
    lines = {}
    for L in np.unique(t["line_id"][g]):
        m = g & (t["line_id"] == L)
        lines[int(L)] = (cfg_of(t[m][0]), m)
    lo, hi = 0.1, 5.0
    boundaries, rejected = [], {}
    for L, (cfg, m) in lines.items():
        for p in PARAMS:
            r = fits.get(f"{pre(p)}grid|{L}|{p}")
            if r is None:
                continue
            ok, why = accept(r, p, lo, hi)
            rejected.setdefault(p, {}).setdefault(why, 0)
            rejected[p][why] += 1
            if not ok:
                continue
            unres = bool(np.isfinite(r["step_dec"]) and r["w_dec"] < r["step_dec"])
            boundaries.append(dict(
                param=p, group=PARAMS[p][0], shape=cfg[0], s=cfg[1], H=cfg[2], h_over_zi=cfg[3], line_id=L,
                fr_c=round(r["x_c"], 4), fr_c_ci=[round(v, 4) for v in r["x_c_ci"]], w_dec=round(r["w_dec"], 4),
                w_ci=[round(v, 4) for v in r["w_ci"]], cls=klass(r), sharp_p6=bool(r["sharp"]), unresolved=unres, step_dec=round(r["step_dec"], 4),
                dy=round(r["dy"], 4), y0=round(r["y0"], 4), r2=round(r["r2"], 3), jump_max=round(r["jump_max"], 4),
                noise=None if r["noise"] is None else round(r["noise"], 5), n=r["n"],
                u10_at_frc=round(interp_log(r["x_c"], t["fr"][m], t["u10"][m]), 3),
                zi_over_L_at_frc=(round(interp_log(r["x_c"], t["fr"][m], t["zi_over_L"][m]), 2) if cfg[2] > 0 else 0.0),
                calm=bool(r["x_c"] <= CALM_FR), in_gap=bool(np.isfinite(r["step_dec"]) and r["step_dec"] > GAP_DEC)))
    for b in boundaries:   # поле cls → ключ sharp|smooth по контракту задания
        b["sharp|smooth"] = b["cls"]

    # агрегаты по параметру и фактору
    agg = {}
    for p in PARAMS:
        bs = [b for b in boundaries if b["param"] == p]
        n_lines = sum(1 for L, (cfg, _) in lines.items() if line_ok(PARAMS[p][1], cfg[2]))
        if not bs:
            agg[p] = dict(n=0, n_lines=n_lines, rejected=rejected.get(p, {}))
            continue
        fc = np.array([b["fr_c"] for b in bs])
        w = np.array([b["w_dec"] for b in bs])
        a = dict(n=len(bs), n_lines=n_lines, fr_c_median=float(np.median(fc)), fr_c_p10_p90=np.percentile(fc, [10, 90]).tolist(),
                 w_dec_median=float(np.median(w)), w_dec_p10_p90=np.percentile(w, [10, 90]).tolist(),
                 n_sharp=sum(b["cls"] == "sharp" for b in bs), n_smooth=sum(b["cls"] == "smooth" for b in bs),
                 n_mid=sum(b["cls"] == "mid" for b in bs), n_unresolved=sum(b["unresolved"] for b in bs),
                 n_calm=sum(b["calm"] for b in bs), dy_sign=int(np.sign(np.median([b["dy"] for b in bs]))),
                 n_in_gap=sum(b["in_gap"] for b in bs),
                 n_sharp_by_w=sum(b["w_dec"] < 0.1 for b in bs),
                 n_sharp_by_jump=sum(b["cls"] == "sharp" and b["w_dec"] >= 0.1 for b in bs), rejected=rejected.get(p, {}), by={})
        cl = [b for b in bs if not b["calm"] and not b["in_gap"]]
        if cl:
            zl = [b["zi_over_L_at_frc"] for b in cl if b["H"] > 0 and np.isfinite(b["zi_over_L_at_frc"])]
            a["clean"] = dict(n=len(cl), fr_c_median=round(float(np.median([b["fr_c"] for b in cl])), 3),
                              fr_c_p25_p75=[round(float(v), 3) for v in np.percentile([b["fr_c"] for b in cl], [25, 75])],
                              w_dec_median=round(float(np.median([b["w_dec"] for b in cl])), 3),
                              w_dec_p25_p75=[round(float(v), 3) for v in np.percentile([b["w_dec"] for b in cl], [25, 75])],
                              n_sharp=sum(b["cls"] == "sharp" for b in cl), n_mid=sum(b["cls"] == "mid" for b in cl),
                              n_smooth=sum(b["cls"] == "smooth" for b in cl), n_unresolved=sum(b["unresolved"] for b in cl),
                              u10_median=round(float(np.median([b["u10_at_frc"] for b in cl])), 2),
                              zi_over_L_median_heat=(round(float(np.median(zl)), 1) if zl else None),
                              by={fac: {str(v): dict(n=len(sel), fr_c_median=round(float(np.median([b["fr_c"] for b in sel])), 3),
                                                     w_dec_median=round(float(np.median([b["w_dec"] for b in sel])), 3))
                                        for v in sorted({b[fac] for b in cl}, key=str)
                                        for sel in [[b for b in cl if b[fac] == v]]}
                                  for fac in ("shape", "s", "H", "h_over_zi")})
        for fac, key in (("shape", "shape"), ("s", "s"), ("H", "H"), ("h_over_zi", "h_over_zi")):
            d = {}
            for v in sorted({b[key] for b in bs}, key=str):
                sel = [b for b in bs if b[key] == v]
                d[str(v)] = dict(n=len(sel), fr_c_median=round(float(np.median([b["fr_c"] for b in sel])), 3),
                                 w_dec_median=round(float(np.median([b["w_dec"] for b in sel])), 3),
                                 frac_sharp=round(sum(b["cls"] == "sharp" for b in sel) / len(sel), 2))
            a["by"][fac] = d
        agg[p] = a

    # ---- второй старт: пары
    pos = {c: i for i, c in enumerate(t["case_id"].tolist())}
    ia = np.array([pos[c] for c in pairs["a"]])
    ib = np.array([pos[c] for c in pairs["b"]])
    sa, sb = t["status"][ia], t["status"][ib]
    spa, spb = t["late_spread60_p90"][ia], t["late_spread60_p90"][ib]
    warm_a = t["start_case_id"][ia] >= 0
    cls = np.empty(len(pairs), "U16")
    both_ok = (sa == 0) & (sb == 0)
    both_max = (sa == 1) & (sb == 1)
    sprd = np.maximum(spa, spb)
    # «ветвь» — > 0,1 U_sat не в одной клетке, а в ≥ 1 % объёма ≤ 600 м (p99); одиночный max > 0,1 — «местное»
    cls[both_ok & (pairs["du_max_rel"] <= BRANCH_DU)] = "same"
    cls[both_ok & (pairs["du_max_rel"] > BRANCH_DU) & (pairs["du_p99_rel"] <= BRANCH_DU)] = "local"
    cls[both_ok & (pairs["du_p99_rel"] > BRANCH_DU)] = "branch"
    cls[both_max & (pairs["du50_p90_ms"] <= sprd)] = "wander_same"
    cls[both_max & (pairs["du50_p90_ms"] > sprd)] = "wander_far"
    dif = sa != sb
    cls[dif & (pairs["du50_p90_ms"] <= sprd)] = "conv_diff_near"
    cls[dif & (pairs["du50_p90_ms"] > sprd)] = "conv_diff_far"
    fr = t["fr"][ia]
    pair_sum = {}
    for kind, name in ((0, "warm_vs_cold"), (1, "up_vs_down")):
        k = (pairs["kind"] == kind) & (warm_a if kind == 0 else True)
        d = dict(n=int(k.sum()), classes={c: int(((cls == c) & k).sum()) for c in np.unique(cls[k])})
        for band, (f0, f1) in (("calm_fr_le_0.45", (0, 0.451)), ("fr_0.5_0.6", (0.49, 0.61)), ("fr_ge_0.8", (0.79, 9))):
            kb = k & (fr >= f0) & (fr <= f1)
            if not kb.any():
                continue
            d[band] = dict(n=int(kb.sum()), classes={c: int(((cls == c) & kb).sum()) for c in np.unique(cls[kb])},
                           du_max_rel_median_both_ok=(float(np.median(pairs["du_max_rel"][kb & both_ok])) if (kb & both_ok).any() else None),
                           du_max_rel_p95_both_ok=(float(np.percentile(pairs["du_max_rel"][kb & both_ok], 95)) if (kb & both_ok).any() else None),
                           conv_a=float((sa[kb] == 0).mean()) if kb.any() else None,
                           conv_b=float((sb[kb] == 0).mean()) if kb.any() else None)
        pair_sum[name] = d
    cold = (pairs["kind"] == 0) & ~warm_a
    pair_sum["cold_vs_cold_repeat"] = dict(n=int(cold.sum()), du_max_rel_max=float(pairs["du_max_rel"][cold].max()) if cold.any() else None,
                                           same_status=float((sa[cold] == sb[cold]).mean()) if cold.any() else None)
    # расхождение сошедшихся пар по Fr (м/с и доли U) и смещение «вверх − вниз» параметров (память начального
    # приближения: систематический знак при |среднее| ≪ физического минимума)
    by_fr = {}
    for kind, name in ((0, "warm_vs_cold"), (1, "up_vs_down")):
        k0 = both_ok & (pairs["kind"] == kind) & warm_a
        d = {}
        for f in np.unique(np.round(fr[k0], 3)):
            k = k0 & (np.abs(fr - f) < 1e-3)
            us_ = t["u_sat"][ia[k]].astype(float)
            d[str(f)] = dict(n=int(k.sum()), u_sat=round(float(us_.mean()), 2),
                             du_p99_ms_median=round(float(np.median(pairs["du_p99_rel"][k] * us_)), 4),
                             du_max_ms_median=round(float(np.median(pairs["du_max_rel"][k] * us_)), 4),
                             frac_p99_gt01=round(float((pairs["du_p99_rel"][k] > BRANCH_DU).mean()), 3),
                             iters_a=float(np.median(t["iters"][ia[k]])), iters_b=float(np.median(t["iters"][ib[k]])))
        by_fr[name] = d
    bias = {}
    for band, (f0, f1) in (("fr_0.3_0.6", (0.29, 0.61)), ("fr_0.8_1.3", (0.79, 1.31))):
        k = both_ok & (pairs["kind"] == 1) & (fr >= f0) & (fr <= f1)
        bb = {}
        for q in PARAMS:
            if q in ("conv", "spread_rel"):
                continue
            dd = D[q][ia[k]] - D[q][ib[k]]
            dd = dd[np.isfinite(dd)]
            if dd.size < 5 or dd.std() == 0:
                continue
            bb[q] = dict(n=int(dd.size), mean=round(float(dd.mean()), 5), sd=round(float(dd.std()), 5),
                         t=round(float(dd.mean() / (dd.std() / np.sqrt(dd.size))), 1),
                         frac_ge_min_dy=round(float(np.mean(np.abs(dd) >= PARAMS[q][2])), 3))
        bias[band] = bb
    # ветви: список
    br = np.nonzero(cls == "branch")[0]
    branch_list = []
    for q in br:
        r = t[ia[q]]
        branch_list.append(dict(kind=int(pairs["kind"][q]), a=int(pairs["a"][q]), b=int(pairs["b"][q]), fr=round(float(r["fr"]), 3),
                                shape=dec(r["shape"]), s=round(float(r["slope"]), 3), H=float(r["heat_flux_wm2"]),
                                h_over_zi=round(float(r["h_over_zi"]), 3), du_max_rel=round(float(pairs["du_max_rel"][q]), 3),
                                du_p99_rel=round(float(pairs["du_p99_rel"][q]), 3), area_gt01=round(float(pairs["area_gt01"][q]), 4)))
    # сходимость по Fr: холодный GRID, тёплый вверх, тёплый вниз
    conv_by_fr = {}
    for f in np.unique(np.round(t["fr"][t["series"] == SWEEP], 3)):
        row = {}
        for name, m in (("grid_cold", g), ("sweep_up", (t["series"] == SWEEP) & (t["variant"] == b"up") & (t["start_case_id"] >= 0)),
                        ("sweep_down", (t["series"] == SWEEP) & (t["variant"] == b"down") & (t["start_case_id"] >= 0))):
            mm = m & (np.abs(t["fr"] - f) < 1e-3)
            row[name] = round(float((t["status"][mm] == 0).mean()), 3) if mm.any() else None
        conv_by_fr[str(f)] = row
    # разности метрик слоёв (layer_diff) у пар
    ld = {}
    for kind, name in ((0, "warm_vs_cold"), (1, "up_vs_down")):
        k = (pairs["kind"] == kind) & (warm_a if kind == 0 else True)
        res = {}
        for c in ("same", "local", "branch", "wander_same", "wander_far", "conv_diff_near", "conv_diff_far"):
            kc = np.nonzero(k & (cls == c))[0]
            if kc.size == 0:
                continue
            fr_ = {}
            for key in LAYER_DIFF_KEYS:
                vals = []
                for q in kc:
                    a_, b_ = t[ia[q]], t[ib[q]]
                    dd = layer_diff({key: a_[key]}, {key: b_[key]})[key]
                    vals.append(abs(dd))
                vals = np.array(vals)
                hh = t["heat_flux_wm2"][ia[kc]]
                if key.startswith("th_"):
                    vals = vals[hh > 0]
                if vals.size == 0:
                    continue
                fr_[key] = dict(frac_changed=round(float(np.mean(~np.isfinite(vals) | (vals >= LAYER_DIFF_MIN[key]))), 3),
                                abs_median=round(float(np.nanmedian(vals)), 4) if np.isfinite(vals).any() else None)
            if kind == 0:
                for gname in ("th", "sl", "lee"):
                    v = t["ref_iou_" + gname][ia[kc]].astype(float)
                    if gname == "th":
                        v = v[t["heat_flux_wm2"][ia[kc]] > 0]
                    fr_["iou_" + gname] = dict(median=round(float(np.nanmedian(v)), 3) if np.isfinite(v).any() else None,
                                               frac_lt_0_5=round(float(np.nanmean(v < 0.5)), 3) if np.isfinite(v).any() else None)
            res[c] = dict(n=int(kc.size), metrics=fr_)
        ld[name] = res

    # ---- гистерезис: подгонки вверх/вниз
    hyst = []
    s = t["series"] == SWEEP
    up_lines = {}
    for L in np.unique(t["line_id"][s]):
        rr = t[s & (t["line_id"] == L)]
        refl = int(t["line_id"][pos[int(rr["ref_case_id"][0])]])
        up_lines.setdefault(refl, {})[dec(rr[0]["variant"])] = int(L)
    for refl, d in up_lines.items():
        cfg = lines[refl][0]
        for p in PARAMS:
            ru, rd = fits.get(f"{pre(p)}up|{d.get('up')}|{p}"), fits.get(f"{pre(p)}down|{d.get('down')}|{p}")
            rg = fits.get(f"{pre(p)}gridwin|{refl}|{p}")
            if ru is None or rd is None:
                continue
            oku, _ = accept(ru, p, 0.3, 1.3)
            okd, _ = accept(rd, p, 0.3, 1.3)
            okg = rg is not None and accept(rg, p, 0.3, 1.3)[0]
            if not (oku and okd):
                if oku or okd:
                    hyst.append(dict(param=p, shape=cfg[0], s=cfg[1], H=cfg[2], h_over_zi=cfg[3], status="one_side",
                                     fr_c_up=ru["x_c"] if oku else None, fr_c_down=rd["x_c"] if okd else None,
                                     fr_c_grid=rg["x_c"] if okg else None))
                continue
            dl = abs(np.log10(ru["x_c"]) - np.log10(rd["x_c"]))
            w2 = 2 * max(ru["w_dec"], rd["w_dec"], ru["step_dec"] if np.isfinite(ru["step_dec"]) else 0,
                         rd["step_dec"] if np.isfinite(rd["step_dec"]) else 0)
            ci_sep = ru["x_c_ci"][1] < rd["x_c_ci"][0] or rd["x_c_ci"][1] < ru["x_c_ci"][0]
            hyst.append(dict(param=p, shape=cfg[0], s=cfg[1], H=cfg[2], h_over_zi=cfg[3], status="both",
                             fr_c_up=round(ru["x_c"], 4), fr_c_down=round(rd["x_c"], 4),
                             fr_c_grid=round(rg["x_c"], 4) if okg else None, w_up=round(ru["w_dec"], 4),
                             w_down=round(rd["w_dec"], 4), dlog=round(dl, 4), two_w=round(w2, 4),
                             ci_separated=bool(ci_sep), hysteresis=bool(dl > w2 and ci_sep),
                             flat_2w=bool(dl > 2 * max(ru["w_dec"], rd["w_dec"]))))
    hsum = {}
    for p in PARAMS:
        hb = [h for h in hyst if h["param"] == p and h["status"] == "both"]
        if not hb:
            continue
        hsum[p] = dict(n_both=len(hb), n_one_side=sum(1 for h in hyst if h["param"] == p and h["status"] == "one_side"),
                       n_hysteresis=sum(h["hysteresis"] for h in hb), n_flat_2w=sum(h["flat_2w"] for h in hb),
                       dlog_median=round(float(np.median([h["dlog"] for h in hb])), 4),
                       dlog_max=round(float(np.max([h["dlog"] for h in hb])), 4),
                       two_w_median=round(float(np.median([h["two_w"] for h in hb])), 4),
                       median_fr_c_up=round(float(np.median([h["fr_c_up"] for h in hb])), 3),
                       median_fr_c_down=round(float(np.median([h["fr_c_down"] for h in hb])), 3),
                       cases=[h for h in hb if h["hysteresis"]])
    allp = {}
    for p in PARAMS:
        if p in ("conv", "spread_rel"):
            continue
        acc = [fits[f"grid|{L}|{p}"] for L in lines if f"grid|{L}|{p}" in fits]
        acc = [r for r in acc if accept(r, p, lo, hi)[0]]
        if acc:
            allp[p] = dict(n=len(acc), fr_c_median=round(float(np.median([r["x_c"] for r in acc])), 3),
                           w_dec_median=round(float(np.median([r["w_dec"] for r in acc])), 3),
                           n_sharp=sum(r["sharp"] for r in acc))
    summary = dict(
        task="AP-8", fit_points="conv/spread_rel — все точки GRID; остальные — только сошедшиеся (status 0; AP-13: "
        "несходимость без нагрева — численный цикл решателя, не фаза)", allpoints_compare=allp, inputs=dict(features=str(FEAT), results=str(RES)), n_grid_lines=len(lines),
        criteria=dict(hysteresis="|lg Fr_c↑ − lg Fr_c↓| > 2·max(w↑, w↓, шаг сетки Fr у x_c, дек) И 95 % бутстрэп-ДИ x_c "
                      "проходов не перекрываются; для сравнения n_flat_2w — плоский критерий §9 п. 6 (> 2·max(w↑, w↓), без шага и ДИ)",
                      branch_du_rel=BRANCH_DU, sharp_w_dec=0.1, smooth_w_dec=0.3, accept="x_c и ДИ в диапазоне Fr, |dy| ≥ MIN_DY, R² ≥ 0,5, w ≤ 1 дек",
                      min_dy={p: v[2] for p, v in PARAMS.items()}, calm_fr=CALM_FR,
                      noise="1,4826·MAD (SWEEP тёплый − GRID) при одинаковом статусе, по базовой линии"),
        params={p: dict(group=v[0], lines=v[1], desc=v[3]) for p, v in PARAMS.items()},
        noise_global=noise["global"], noise_global_converged=noise.get("global_ok"), aggregate=agg, boundaries=boundaries,
        second_start=dict(pairs=pair_sum, layer_diff=ld, branches=branch_list, conv_by_fr=conv_by_fr,
                          converged_pairs_by_fr=by_fr, up_minus_down_bias=bias),
        hysteresis=dict(summary=hsum, n_param_lines_both=sum(1 for h in hyst if h["status"] == "both"),
                        n_hysteresis=sum(1 for h in hyst if h.get("hysteresis")),
                        n_flat_2w=sum(1 for h in hyst if h.get("flat_2w"))),
    )
    (HERE / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1, default=float))
    figures(t, D, fits, boundaries, pairs, cls, ia, hyst, conv_by_fr, lines)
    return summary


def figures(t, D, fits, boundaries, pairs, cls, ia, hyst, conv_by_fr, lines):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from sigmoid import _model
    plt.rcParams.update({"font.size": 9})
    colors = {"HILL": "#1f77b4", "RIDGE": "#d62728", "STEP_UP": "#2ca02c"}
    # 1. примеры: H=0, h/zi=1, s=0.3, три формы — conv, f_turn25, lee_area25, sl_area
    ex = ["conv", "f_turn25", "f_rev25", "lee_area25_km2", "lee_rev_area25_km2", "sl_area_km2"]
    fig, axs = plt.subplots(2, 3, figsize=(12, 6.5))
    for ax, p in zip(axs.ravel(), ex):
        for L, (cfg, m) in lines.items():
            if cfg[1] == 0.3 and cfg[2] == 0 and cfg[3] == 1.0:
                x, y, okm = t["fr"][m], D[p][m], t["status"][m] == 0
                ax.plot(x[okm], y[okm], "o", ms=3, color=colors[cfg[0]], label=cfg[0])
                ax.plot(x[~okm], y[~okm], "x", ms=3, color=colors[cfg[0]], alpha=0.5)
                r = fits.get(f"{pre(p)}grid|{L}|{p}")
                if r and np.isfinite(r["x_c"]):
                    xx = np.logspace(-1, np.log10(5), 200)
                    ax.plot(xx, _model(np.log10(xx), np.log10(r["x_c"]), r["w_dec"], r["y0"], r["dy"]), "-",
                            color=colors[cfg[0]], lw=1)
        ax.axvspan(0.1, CALM_FR, color="0.9", zorder=0)
        ax.set_xscale("log"); ax.set_title(p); ax.set_xlabel("Fr")
    axs[0, 0].legend(fontsize=7)
    fig.suptitle("GRID, s = 0,3, H = 0, h/z_i = 1: o — сошлось, x — не сошлось (late_mean); сигмоида — по сошедшимся")
    fig.tight_layout(); fig.savefig(HERE / "fig_grid_examples.png", dpi=110); plt.close(fig)
    # 2. Fr_c по параметрам (точки — линии), цвет — форма
    ps = [p for p in PARAMS if any(b["param"] == p for b in boundaries)]
    fig, ax = plt.subplots(figsize=(10, 0.32 * len(ps) + 1.5))
    for i, p in enumerate(ps):
        for b in boundaries:
            if b["param"] == p:
                mk = "o" if b["cls"] == "sharp" else ("s" if b["cls"] == "smooth" else "^")
                ax.plot(b["fr_c"], i + np.random.default_rng(b["line_id"]).uniform(-0.25, 0.25), mk, ms=3,
                        color=colors[b["shape"]], alpha=0.7, mfc="none" if b["cls"] == "smooth" else None)
    ax.set_yticks(range(len(ps))); ax.set_yticklabels(ps); ax.set_xscale("log"); ax.set_xlabel("Fr_c")
    ax.axvspan(0.1, CALM_FR, color="0.9", zorder=0)
    ax.set_title("Пороги Fr_c по линиям GRID (о — резкая, △ — промежуточная, □ — плавная; цвет — форма)")
    fig.tight_layout(); fig.savefig(HERE / "fig_frc_by_param.png", dpi=110); plt.close(fig)
    # 3. ширина w против Fr_c
    fig, ax = plt.subplots(figsize=(7, 5))
    for b in boundaries:
        ax.plot(b["fr_c"], b["w_dec"], "o", ms=3, color=colors[b["shape"]], alpha=0.6)
    ax.axhline(0.1, ls="--", c="k", lw=0.8); ax.axhline(0.3, ls=":", c="k", lw=0.8)
    ax.set_xscale("log"); ax.set_yscale("log"); ax.set_xlabel("Fr_c"); ax.set_ylabel("w, декады")
    ax.set_title("Ширина перехода против порога (все параметры; -- 0,1 резкая, ··· 0,3 плавная)")
    fig.tight_layout(); fig.savefig(HERE / "fig_width_vs_frc.png", dpi=110); plt.close(fig)
    # 4. расхождение полей пар против Fr
    fig, axs = plt.subplots(1, 2, figsize=(12, 4.5), sharey=True)
    cc = {"same": "0.6", "local": "#8c564b", "branch": "r", "wander_same": "#1f77b4", "wander_far": "#9467bd", "conv_diff_near": "#2ca02c",
          "conv_diff_far": "#ff7f0e"}
    warm = t["start_case_id"][ia] >= 0
    for ax, kind, title in ((axs[0], 0, "тёплый SWEEP против холодного GRID"), (axs[1], 1, "проход вверх против прохода вниз")):
        k = (pairs["kind"] == kind) & (warm if kind == 0 else True)
        for c, col in cc.items():
            kk = k & (cls == c)
            x = t["fr"][ia[kk]] * np.exp(np.random.default_rng(1).normal(0, 0.015, kk.sum()))
            ax.plot(x, pairs["du_max_rel"][kk], "o", ms=2.5, color=col, label=f"{c} ({kk.sum()})", alpha=0.7)
        ax.axhline(BRANCH_DU, ls="--", c="k", lw=0.8); ax.set_yscale("log"); ax.set_xlabel("Fr"); ax.set_title(title)
        ax.legend(fontsize=7)
    axs[0].set_ylabel("max |Δu_h| / U_sat")
    fig.tight_layout(); fig.savefig(HERE / "fig_second_start.png", dpi=110); plt.close(fig)
    # 5. Fr_c вверх против вниз
    fig, ax = plt.subplots(figsize=(5.5, 5.5))
    for h in hyst:
        if h["status"] == "both":
            ax.plot(h["fr_c_up"], h["fr_c_down"], "o", ms=3, color="r" if h["hysteresis"] else "0.4", alpha=0.6)
    ax.plot([0.3, 1.3], [0.3, 1.3], "k-", lw=0.6); ax.set_xscale("log"); ax.set_yscale("log")
    ax.set_xlabel("Fr_c, проход вверх"); ax.set_ylabel("Fr_c, проход вниз")
    ax.set_title("Гистерезис: пороги на проходах (красное — |Δlg| > 2w)")
    fig.tight_layout(); fig.savefig(HERE / "fig_hysteresis.png", dpi=110); plt.close(fig)
    # 6. сходимость по Fr: холодный, тёплый вверх, тёплый вниз
    fig, ax = plt.subplots(figsize=(6.5, 4.5))
    fs = sorted(conv_by_fr, key=float)
    for name, st in (("grid_cold", "k-o"), ("sweep_up", "r-^"), ("sweep_down", "b-v")):
        ax.plot([float(f) for f in fs], [conv_by_fr[f][name] for f in fs], st, ms=4, label=name)
    ax.axvspan(0.3, CALM_FR, color="0.9", zorder=0); ax.set_xlabel("Fr"); ax.set_ylabel("доля сошедшихся")
    ax.legend(); ax.set_title("Сходимость Пикара: холодный старт против тёплого (вверх/вниз по Fr)")
    fig.tight_layout(); fig.savefig(HERE / "fig_convergence_starts.png", dpi=110); plt.close(fig)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--workers", type=int, default=max(1, min(16, (os.cpu_count() or 2) - 2)))
    ap.add_argument("--n-boot", type=int, default=200)
    ap.add_argument("--stage", default="all", choices=["all", "pairs", "fits", "fits_ok", "report"])
    a = ap.parse_args(argv)
    t = load_table()
    D = derived(t)
    if a.stage in ("all", "pairs") or not (HERE / "pairs.npz").exists():
        pairs = stage_pairs(t, a.workers)
    else:
        pairs = np.load(HERE / "pairs.npz")["pairs"]
    if a.stage == "pairs":
        return
    if a.stage in ("all", "fits") or not (OUT / "fits.json").exists():
        fits, noise = stage_fits(t, D, a.workers, a.n_boot)
    else:
        j = json.loads((OUT / "fits.json").read_text())
        fits, noise = j["fits"], j["noise"]
    if a.stage in ("all", "fits", "fits_ok") or not (OUT / "fits_ok.json").exists():
        fo, no = stage_fits(t, D, a.workers, a.n_boot, ok=True)
    else:
        j = json.loads((OUT / "fits_ok.json").read_text())
        fo, no = j["fits"], j["noise"]
    fits.update(fo)
    noise = dict(noise, global_ok=no["global"])
    if a.stage in ("fits", "fits_ok"):
        return
    s = stage_report(t, D, fits, noise, pairs)
    print(json.dumps(dict(n_boundaries=len(s["boundaries"]), n_hyst=s["hysteresis"]["n_hysteresis"]), ensure_ascii=False))


if __name__ == "__main__":
    main()
