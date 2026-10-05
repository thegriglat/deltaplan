#!/usr/bin/env python3
"""air-phase: эмпирическая «фазовая диаграмма» по готовым полям решателя SY-12 (CPU, без GPU и Godot).

Читает решения S5 v4 (`~/air_synth_data/solve/hg_v2__hgw24__s0-939a467/part-*.h5`), условия S2 v4
(`~/air_synth_data/conditions/hg_v2_hgw24`), сводку рельефов (`~/air_synth_data/real/hg_v2`), считает на случай
параметры порядка (обратное течение, застой/обход, волновая амплитуда, конвективная добавка, …) и сводит их с поведением
Пикара (статус, итерации, разброс поздних итераций) по осям Fr, w*/U, −z_i/L, крутизна, h/z_i.

  PY=/home/greg/deltaplan-air-synth-SY-11/tools/research/air_nn_pilot/.venv/bin/python
  $PY tools/research/air_phase/phase_stats.py                 # всё: признаки (кэш out/per_case.npz) + таблицы + рисунки
  $PY tools/research/air_phase/phase_stats.py --recompute     # пересчитать признаки из полей (~5–10 мин CPU)
  $PY tools/research/air_phase/phase_stats.py --solve DIR --conditions DIR --relief DIR --out DIR

Выход: out/per_case.npz (признаки на случай), out/tables.md, out/summary.json, out/fig_*.png.
Документ: docs/research/air_phase.md."""
from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path

import h5py
import numpy as np

HERE = Path(__file__).resolve().parent
DATA = Path(os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data")))
AGL = np.array([25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000], float)
DX = 400.0
EDGE = 5                       # край области вне статистик (как late_spread60_p90)
KAPPA, G, TH0, RHO_CP, Z0 = 0.4, 9.81, 300.0, 1206.0, 0.1
L_IDX = {int(a): i for i, a in enumerate(AGL)}


# ------------------------------------------------------------------ признаки на случай
def inflow_speed(u10, alpha, max_profile, z):
    """Профиль притока решателя (wind_prof C2 v4): U10·min((z/z_sat)^α, 1), z_sat = 10·max_profile^(1/α)."""
    z_sat = 10.0 * max_profile ** (1.0 / alpha)
    return u10 * min((max(z, Z0) / z_sat) ** alpha, 1.0)


def terrain_features(hc):
    """Рельеф области: перепад, уклон на 400 м (средний, p95), локальный перепад (окно 11 клеток = 4,4 км)."""
    gy, gx = np.gradient(hc, DX)
    s = np.hypot(gx, gy)
    i = slice(EDGE, -EDGE)
    from scipy.ndimage import maximum_filter, minimum_filter
    loc = maximum_filter(hc, 11) - minimum_filter(hc, 11)
    return dict(relief_m=float(hc.max() - hc.min()), slope400_mean=float(s[i, i].mean()), slope400_p95=float(np.percentile(s[i, i], 95)),
                slope400_max=float(s[i, i].max()), h_std=float(hc[i, i].std()), local_relief_p50=float(np.median(loc[i, i])),
                local_relief_p90=float(np.percentile(loc[i, i], 90)))


def field_features(f, e, u10, alpha, mp, prefix):
    """Параметры порядка по полю (C, 13, 96, 96): C = 3 (u,v,w) или 4 (+θ′). e — единичный вектор «куда дует»."""
    i = slice(EDGE, -EDGE)
    out = {}
    u, v, w = (np.asarray(f[c], np.float32) for c in range(3))
    for lev in (25, 50, 100):
        k = L_IDX[lev]
        ub = inflow_speed(u10, alpha, mp, lev)
        along = (u[k] * e[0] + v[k] * e[1])[i, i]
        sp = np.hypot(u[k], v[k])[i, i]
        out[f"{prefix}_rev{lev}"] = float((along < -0.05 * max(ub, 0.3)).mean())        # обратное течение (доля клеток)
        out[f"{prefix}_stag{lev}"] = float((sp < 0.3 * ub).mean())                      # застой: < 30 % притока
        cosang = along / np.maximum(sp, 1e-3)
        out[f"{prefix}_turn{lev}"] = float(((cosang < np.cos(np.radians(45))) & (sp > 0.2 * ub)).mean())  # поворот > 45° (обход)
        out[f"{prefix}_speed{lev}"] = float(sp.mean() / max(ub, 1e-3))                  # средняя скорость / приток
        out[f"{prefix}_speedup{lev}"] = float(np.percentile(sp, 99) / max(ub, 1e-3))     # разгон p99
    for lev in (300, 600, 800):
        k = L_IDX[lev]
        ww = w[k][i, i]
        out[f"{prefix}_wstd{lev}"] = float(ww.std())
        out[f"{prefix}_wmax{lev}"] = float(np.abs(ww).max())
        m3 = float(np.mean((ww - ww.mean()) ** 3))
        out[f"{prefix}_wskew{lev}"] = float(m3 / max(ww.std(), 1e-4) ** 3)
    if f.shape[0] == 4:
        th = np.asarray(f[3], np.float32)
        out[f"{prefix}_th25_mean"] = float(th[0][i, i].mean())
        out[f"{prefix}_th25_p99"] = float(np.percentile(th[0][i, i], 99))
        out[f"{prefix}_th25_p01"] = float(np.percentile(th[0][i, i], 1))
    return out


def compute(solve_dir, cond_dir, relief_dir, limit=None):
    parts = sorted(glob.glob(os.path.join(solve_dir, "part-*.h5")))
    ct = np.concatenate([h5py.File(p, "r")["conditions/table"][:] for p in sorted(glob.glob(os.path.join(cond_dir, "part-*.h5")))])
    cmap = {(int(r["relief_id"]), int(r["cond_id"])): r for r in ct}
    rs = np.concatenate([h5py.File(p, "r")["summary"][:] for p in sorted(glob.glob(os.path.join(relief_dir, "part-*.h5")))])
    rmap = {int(r["id"]): r for r in rs}
    rows, tcache = [], {}
    n = 0
    for p in parts:
        with h5py.File(p, "r") as f:
            cases = f["cases"][:]
            fm, fh, hcs, hf = f["fields/m"], f["fields/h"], f["inputs/hc"], f["inputs/heat_flux"]
            for j, c in enumerate(cases):
                rid, cid = int(c["relief_id"]), int(c["cond_id"])
                cr = cmap[(rid, cid)]
                rr = rmap[rid]
                u10, alpha, mp = float(cr["u10_m_s"]), float(cr["alpha"]), float(cr["max_profile"])
                phi = np.radians(float(cr["wind_from_deg"]))
                e = (-np.sin(phi), -np.cos(phi))
                hc = np.asarray(hcs[j], np.float64)
                if rid not in tcache:
                    tcache[rid] = terrain_features(hc)
                d = dict(case=int(c["case"]), relief_id=rid, cond_id=cid, group=int(c["group"]), status_m=int(c["status_m"]), status_h=int(c["status_h"]),
                         iters_m=int(c["iters_m"]), iters_h=int(c["iters_h"]), spread_m=float(c["late_spread60_p90_m"]), spread_h=float(c["late_spread60_p90_h"]),
                         seconds=float(c["seconds"]))
                for k in ("u10_m_s", "wind_from_deg", "hour_local", "froude", "n_bv_s", "z_i_m", "hs_w_m2", "w_star_m_s", "w_star_over_u", "alpha",
                          "max_profile", "u_sat_m_s", "stability_class", "has_cap", "cap_agl_m", "dtheta_dz_k_per_km", "cloud_cover", "mechanical", "month"):
                    d[k] = float(cr[k])
                d["slope_p95_deg_100"] = float(rr["slope_p95_deg_100"]); d["slope_mean_deg_400"] = float(rr["slope_mean_deg_400"])
                d.update(tcache[rid])
                H = np.asarray(hf[j], np.float32)
                d["H_mean"] = float(H.mean()); d["H_neg_frac"] = float((H < -1).mean()); d["H_min"] = float(H.min()); d["H_max"] = float(H.max())
                d["z_i_agl"] = float(cr["z_i_m"]) - float(hc.mean())
                # −z_i/L по фону решателя: u* = κU10/ln(10/z0); L = −u*³θ0/(κ g H/(ρc_p))
                us = KAPPA * u10 / np.log(10.0 / Z0)
                hk = max(d["H_mean"], 0.0) / RHO_CP
                d["u_star"] = us
                d["zi_over_L"] = float(KAPPA * G / TH0 * hk * max(d["z_i_agl"], 1.0) / max(us, 1e-3) ** 3)     # = −z_i/L ≥ 0
                d.update(field_features(fm[j], e, u10, alpha, mp, "m"))
                d.update(field_features(fh[j], e, u10, alpha, mp, "h"))
                # конвективная добавка: разность полей с нагревом и без
                k50, k300 = L_IDX[50], L_IDX[300]
                i = slice(EDGE, -EDGE)
                dm, dh = np.asarray(fm[j], np.float32), np.asarray(fh[j], np.float32)
                ub = inflow_speed(u10, alpha, mp, 50)
                d["dh_rms50"] = float(np.sqrt(((dh[0, k50] - dm[0, k50]) ** 2 + (dh[1, k50] - dm[1, k50]) ** 2)[i, i].mean()))
                d["dh_rms50_rel"] = d["dh_rms50"] / max(ub, 0.3)
                d["dw300_rms"] = float(np.sqrt(((dh[2, k300] - dm[2, k300]) ** 2)[i, i].mean()))
                d["dw300_pos_mean"] = float(np.maximum(dh[2, k300] - dm[2, k300], 0)[i, i].mean())
                rows.append(d)
                n += 1
                if limit and n >= limit:
                    break
        print(f"{p}: всего {n}", flush=True)
        if limit and n >= limit:
            break
    keys = sorted(rows[0])
    return {k: np.array([r[k] for r in rows]) for k in keys}


# ------------------------------------------------------------------ статистика
def wilson(k, n, z=1.96):
    if n == 0:
        return (np.nan, np.nan, np.nan)
    p = k / n
    den = 1 + z * z / n
    c = (p + z * z / (2 * n)) / den
    h = z * np.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return p, c - h, c + h


def binned_rate(x, y, edges):
    """Доля y по корзинам x: (центры, доля, n, нижняя, верхняя)."""
    out = []
    for a, b in zip(edges[:-1], edges[1:]):
        m = (x >= a) & (x < b)
        n = int(m.sum())
        p, lo, hi = wilson(float(y[m].sum()), n) if n else (np.nan, np.nan, np.nan)
        out.append((np.sqrt(a * b) if a > 0 else 0.5 * (a + b), p, n, lo, hi))
    return np.array(out).T


def logistic(X, y, iters=50, l2=1e-3):
    """Логистическая регрессия IRLS (стандартизованные признаки) → коэффициенты, их СКО."""
    Xs = (X - X.mean(0)) / X.std(0)
    A = np.c_[np.ones(len(Xs)), Xs]
    w = np.zeros(A.shape[1])
    for _ in range(iters):
        p = 1 / (1 + np.exp(-A @ w))
        W = p * (1 - p)
        Hm = A.T @ (A * W[:, None]) + l2 * np.eye(A.shape[1])
        g = A.T @ (y - p) - l2 * w
        step = np.linalg.solve(Hm, g)
        w += step
        if np.abs(step).max() < 1e-8:
            break
    p = 1 / (1 + np.exp(-A @ w))
    cov = np.linalg.inv(A.T @ (A * (p * (1 - p))[:, None]) + l2 * np.eye(A.shape[1]))
    ll = float(np.sum(y * np.log(p + 1e-12) + (1 - y) * np.log(1 - p + 1e-12)))
    return w, np.sqrt(np.diag(cov)), ll


def sigmoid_fit(x, y, x0_grid, k_grid):
    """Подгонка p(x) = 1/(1+exp(−k(x−x0))) по максимуму правдоподобия на сетке → (x0, k, ширина 10–90 % = 4,39/k)."""
    best = (None, None, -np.inf)
    for x0 in x0_grid:
        for k in k_grid:
            p = 1 / (1 + np.exp(-k * (x - x0)))
            ll = np.sum(y * np.log(p + 1e-9) + (1 - y) * np.log(1 - p + 1e-9))
            if ll > best[2]:
                best = (x0, k, ll)
    return best[0], best[1], 4.394 / abs(best[1])


def fmt(v, d=2):
    return "—" if v is None or (isinstance(v, float) and not np.isfinite(v)) else f"{v:.{d}f}"


def analyse(D, out, tag):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.size": 9, "axes.grid": True, "grid.alpha": 0.3})
    S = {}
    T = []
    n = len(D["case"])
    fr = np.clip(D["froude"], 1e-3, 1e3)
    ncm, nch = (D["status_m"] != 0).astype(float), (D["status_h"] != 0).astype(float)
    both = ((D["status_m"] != 0) & (D["status_h"] != 0)).sum()
    S["n"] = n
    S["nonconv_m"] = dict(frac=float(ncm.mean()), n=int(ncm.sum()))
    S["nonconv_h"] = dict(frac=float(nch.mean()), n=int(nch.sum()))
    S["nonconv_both"] = int(both)
    S["diverged"] = int(((D["status_m"] == 2) | (D["status_h"] == 2)).sum())
    T.append(f"## Сходимость ({tag}, {n} случаев)\n\nбез нагрева (m): {ncm.mean():.3f} ({int(ncm.sum())}); с нагревом (h): {nch.mean():.3f} ({int(nch.sum())}); "
             f"в обоих: {both}; разошлось: {S['diverged']}.\n")
    # условия: квантили осей
    T.append("## Распределение осей (квантили 5 / 50 / 95 %)\n\n| ось | 5 % | 50 % | 95 % |\n|---|---|---|---|")
    for k, lab in (("froude", "Fr = U_sat/(N·Δh)"), ("w_star_over_u", "w*/U"), ("zi_over_L", "−z_i/L"), ("u10_m_s", "U10, м/с"), ("hs_w_m2", "H, Вт/м²"),
                   ("z_i_agl", "z_i над землёй, м"), ("n_bv_s", "N, 1/с"), ("relief_m", "Δh области, м"), ("slope400_p95", "уклон p95 на 400 м"),
                   ("slope_p95_deg_100", "уклон p95 на 100 м, °"), ("local_relief_p90", "местный перепад p90 (4,4 км), м")):
        q = np.nanpercentile(D[k], [5, 50, 95])
        T.append(f"| {lab} | {fmt(q[0], 3)} | {fmt(q[1], 3)} | {fmt(q[2], 3)} |")
        S[f"q_{k}"] = q.tolist()
    hzi = D["relief_m"] / np.maximum(D["z_i_agl"], 1)
    S["frac_h_over_zi_gt1"] = float((hzi > 1).mean())
    S["frac_H_neg_cells"] = float((D["H_neg_frac"] > 0.5).mean())
    T.append(f"\nДоля случаев с Δh/z_i > 1 (рельеф пробивает верх слоя): {S['frac_h_over_zi_gt1']:.3f}; "
             f"случаев, где поток тепла отрицателен на > 50 % клеток: {S['frac_H_neg_cells']:.3f}; H_mean < 0: {(D['H_mean'] < 0).mean():.3f}.\n")

    # --- несходимость по Fr (тонкие корзины), m и h
    fe = np.array([0.03, 0.06, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.5, 0.6, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.5, 5, 7, 10, 20, 1000])
    bm, bh = binned_rate(fr, ncm, fe), binned_rate(fr, nch, fe)
    T.append("## Доля несошедшихся по Fr (решение без нагрева m / с нагревом h)\n\n| Fr от | до | n | m | h | медиана итераций сошедшихся m | p90 разброса поздних m, м/с |\n|---|---|---|---|---|---|---|")
    it_med = []
    for a, b, pm, ph, nn in zip(fe[:-1], fe[1:], bm[1], bh[1], bm[2]):
        m = (fr >= a) & (fr < b)
        okm = m & (D["status_m"] == 0)
        med = float(np.median(D["iters_m"][okm])) if okm.any() else np.nan
        sp = float(np.percentile(D["spread_m"][m & (D["status_m"] != 0)], 90)) if (m & (D["status_m"] != 0)).any() else np.nan
        it_med.append(med)
        T.append(f"| {a:g} | {b:g} | {int(nn)} | {fmt(pm)} | {fmt(ph)} | {fmt(med, 0)} | {fmt(sp)} |")
    S["nonconv_by_fr"] = dict(edges=fe.tolist(), m=bm[1].tolist(), h=bh[1].tolist(), n=bm[2].tolist(), iters_med_m=it_med)
    # сигмоида по log Fr
    lx = np.log10(fr)
    x0, k, wd = sigmoid_fit(lx, ncm, np.linspace(-1.5, 1, 101), -np.linspace(0.3, 8, 78))
    S["sigmoid_fr_m"] = dict(fr50=10 ** x0, k=k, width_decades=wd, fr10_90=[10 ** (x0 - wd / 2), 10 ** (x0 + wd / 2)])
    # асимптоты: нижняя/верхняя полки
    lo_frac = float(ncm[fr < 0.1].mean()) if (fr < 0.1).any() else np.nan
    hi_frac = float(ncm[fr > 3].mean())
    T.append(f"\nСигмоида P(несход. m) по log₁₀ Fr: середина Fr₅₀ = {10 ** x0:.2f}, ширина 10–90 % = {wd:.2f} декады "
             f"(Fr {10 ** (x0 - wd / 2):.2f}…{10 ** (x0 + wd / 2):.2f}); полки: Fr < 0,1 → {lo_frac:.2f}, Fr > 3 → {hi_frac:.3f}. "
             "Низкая полка < 1 означает: даже при сильном блокировании больше половины случаев сходится — граница не в Fr одном.\n")

    # --- разделимость: кривые по Fr для терцилей w*/U, крутизны, h/z_i, U10
    def tercile_curves(key, label, edges=np.array([0.03, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2.5, 5, 1000]), q=(1 / 3, 2 / 3)):
        v = D[key]
        qs = np.nanquantile(v, q)
        groups = [(v < qs[0], f"{label} < {qs[0]:.2g}"), ((v >= qs[0]) & (v < qs[1]), f"{qs[0]:.2g}…{qs[1]:.2g}"), (v >= qs[1], f"{label} ≥ {qs[1]:.2g}")]
        res = []
        for m, lab in groups:
            b = binned_rate(fr[m], ncm[m], edges)
            res.append((lab, b))
        return res, edges

    sep = {}
    T.append("## Разделимость: P(несход. m) по Fr в терцилях других осей\n")
    for key, label in (("w_star_over_u", "w*/U"), ("zi_over_L", "−z_i/L"), ("slope400_p95", "уклон p95 (400 м)"), ("slope_p95_deg_100", "уклон p95 (100 м), °"),
                       ("relief_m", "Δh, м"), ("u10_m_s", "U10")):
        res, edges = tercile_curves(key, label)
        T.append(f"### {label}\n\n| Fr от | до | " + " | ".join(f"{lab} (n)" for lab, _ in res) + " |\n|---|---|" + "---|" * len(res))
        maxdiff = []
        for i, (a, b) in enumerate(zip(edges[:-1], edges[1:])):
            vals = [r[1][1][i] for r in res]
            ns = [int(r[1][2][i]) for r in res]
            T.append(f"| {a:g} | {b:g} | " + " | ".join(f"{fmt(v)} ({nn})" for v, nn in zip(vals, ns)) + " |")
            if min(ns) >= 30:
                maxdiff.append(float(np.nanmax(vals) - np.nanmin(vals)))
        sep[key] = dict(max_diff_between_terciles=float(np.nanmax(maxdiff)) if maxdiff else np.nan, mean_diff=float(np.nanmean(maxdiff)) if maxdiff else np.nan)
        T.append(f"\nМаксимальный разброс долей между терцилями в корзинах с n ≥ 30: {sep[key]['max_diff_between_terciles']:.2f}, средний {sep[key]['mean_diff']:.2f}.\n")
    S["separability"] = sep

    # --- логистическая регрессия
    feats = [("log Fr", np.log10(fr)), ("log U10", np.log10(np.maximum(D["u10_m_s"], 0.1))), ("log(1+w*/U)", np.log10(1 + D["w_star_over_u"])),
             ("уклон p95 400 м", D["slope400_p95"]), ("log Δh/z_i", np.log10(np.clip(hzi, 1e-2, 1e2))), ("N", D["n_bv_s"]), ("log Δh", np.log10(D["relief_m"]))]
    X = np.c_[[f[1] for f in feats]].T
    w, se, ll = logistic(X, ncm)
    w0, _, ll0 = logistic(X[:, :1] * 0 + 1e-9 * np.random.default_rng(0).standard_normal((n, 1)), ncm)
    S["logit_m"] = {f[0]: dict(coef=float(w[i + 1]), se=float(se[i + 1])) for i, f in enumerate(feats)}
    S["logit_m"]["loglik"] = ll
    T.append("## Логистическая регрессия: P(несход. m) по стандартизованным признакам\n\n| признак | коэффициент (на 1 СКО) | СКО |\n|---|---|---|")
    for i, f in enumerate(feats):
        T.append(f"| {f[0]} | {w[i + 1]:+.2f} | {se[i + 1]:.2f} |")
    # по одному признаку: как падает правдоподобие без него
    T.append("\nВклад признаков (прирост log-правдоподобия при добавлении признака к остальным):\n\n| признак | Δ log L |\n|---|---|")
    for i, f in enumerate(feats):
        Xi = np.delete(X, i, axis=1)
        _, _, lli = logistic(Xi, ncm)
        T.append(f"| {f[0]} | {ll - lli:.1f} |")
        S["logit_m"][f[0]]["dloglik"] = ll - lli

    # --- критическое замедление: итерации сошедшихся vs Fr; разброс поздних итераций
    ok = D["status_m"] == 0
    T.append("\n## Итерации сошедшихся (m) и разброс поздних итераций несошедшихся по Fr\n\n| Fr от | до | n ok | медиана итераций | p90 | n max | медиана разброса p90@60 м, м/с | p90 |\n|---|---|---|---|---|---|---|---|")
    fe2 = np.array([0.03, 0.1, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 1.5, 2.5, 5, 10, 1000])
    crit = []
    for a, b in zip(fe2[:-1], fe2[1:]):
        m = (fr >= a) & (fr < b)
        it = D["iters_m"][m & ok]
        sp = D["spread_m"][m & ~ok]
        row = dict(lo=a, hi=b, n_ok=int((m & ok).sum()), it_med=float(np.median(it)) if len(it) else np.nan, it_p90=float(np.percentile(it, 90)) if len(it) else np.nan,
                   n_max=int((m & ~ok).sum()), sp_med=float(np.median(sp)) if len(sp) else np.nan, sp_p90=float(np.percentile(sp, 90)) if len(sp) else np.nan)
        crit.append(row)
        T.append(f"| {a:g} | {b:g} | {row['n_ok']} | {fmt(row['it_med'], 0)} | {fmt(row['it_p90'], 0)} | {row['n_max']} | {fmt(row['sp_med'])} | {fmt(row['sp_p90'])} |")
    S["critical_slowing"] = crit
    S["spread_nonconv_m"] = dict(median=float(np.median(D["spread_m"][~ok])), p90=float(np.percentile(D["spread_m"][~ok], 90)), max=float(D["spread_m"][~ok].max()))
    S["spread_nonconv_m_rel_u10"] = dict(median=float(np.median((D["spread_m"] / np.maximum(D["u10_m_s"], 0.1))[~ok])))
    S["iters_nonconv_all_1000"] = bool((D["iters_m"][~ok] >= 1000).all())

    # --- параметры порядка
    T.append("\n## Параметры порядка по осям (медианы)\n")
    T.append("### Обход и застой у земли (решение m, 25 м) по Fr\n\n| Fr от | до | n | обратное течение, доля | застой (< 0,3 U), доля | поворот > 45°, доля | средняя скорость / приток | разгон p99 / приток | σ_w на 600 м / U_sat | σ_w на 800 м, м/с |\n|---|---|---|---|---|---|---|---|---|---|")
    op = []
    for a, b in zip(fe2[:-1], fe2[1:]):
        m = (fr >= a) & (fr < b)
        if not m.any():
            continue
        r = dict(lo=a, hi=b, n=int(m.sum()), rev=float(np.median(D["m_rev25"][m])), stag=float(np.median(D["m_stag25"][m])), turn=float(np.median(D["m_turn25"][m])),
                 speed=float(np.median(D["m_speed25"][m])), speedup=float(np.median(D["m_speedup50"][m])),
                 wstd600_rel=float(np.median((D["m_wstd600"] / np.maximum(D["u_sat_m_s"], 0.3))[m])), wstd800=float(np.median(D["m_wstd800"][m])))
        op.append(r)
        T.append(f"| {a:g} | {b:g} | {r['n']} | {r['rev']:.3f} | {r['stag']:.3f} | {r['turn']:.3f} | {r['speed']:.2f} | {r['speedup']:.2f} | {r['wstd600_rel']:.3f} | {r['wstd800']:.2f} |")
    S["order_by_fr"] = op
    # обратное течение vs крутизна (при Fr > 1,5 — чистая механика)
    T.append("\n### Обратное течение (m, 25 м) по крутизне, случаи Fr > 1,5\n\n| уклон p95 (100 м), ° от | до | n | медиана доли обратного течения | p90 | медиана доли застоя |\n|---|---|---|---|---|---|")
    se_ = np.array([0, 10, 15, 20, 25, 30, 35, 40, 60])
    hi = fr > 1.5
    sl = []
    for a, b in zip(se_[:-1], se_[1:]):
        m = hi & (D["slope_p95_deg_100"] >= a) & (D["slope_p95_deg_100"] < b)
        if m.sum() < 5:
            continue
        r = dict(lo=a, hi=b, n=int(m.sum()), rev_med=float(np.median(D["m_rev25"][m])), rev_p90=float(np.percentile(D["m_rev25"][m], 90)), stag=float(np.median(D["m_stag25"][m])))
        sl.append(r)
        T.append(f"| {a} | {b} | {r['n']} | {r['rev_med']:.3f} | {r['rev_p90']:.3f} | {r['stag']:.3f} |")
    S["rev_by_slope_highfr"] = sl
    # несходимость по крутизне при Fr > 1,5 и при Fr < 0,5
    T.append("\n### Несходимость (m) по крутизне и Fr\n\n| уклон p95 (100 м), ° | Fr < 0,5 | 0,5–1,5 | Fr > 1,5 |\n|---|---|---|---|")
    nsl = []
    for a, b in zip(se_[:-1], se_[1:]):
        ms = (D["slope_p95_deg_100"] >= a) & (D["slope_p95_deg_100"] < b)
        cells = []
        for fm_ in ((fr < 0.5), (fr >= 0.5) & (fr < 1.5), fr >= 1.5):
            mm = ms & fm_
            cells.append((float(ncm[mm].mean()) if mm.sum() else np.nan, int(mm.sum())))
        nsl.append(dict(lo=a, hi=b, cells=cells))
        T.append(f"| {a}–{b} | " + " | ".join(f"{fmt(c[0])} ({c[1]})" for c in cells) + " |")
    S["nonconv_by_slope_fr"] = nsl
    # конвективная добавка vs w*/U и −z_i/L
    T.append("\n### Конвективная добавка (h − m) по w*/U\n\n| w*/U от | до | n | СКО Δu_h на 50 м / приток | СКО Δw на 300 м, м/с | асимметрия w_h на 300 м | асимметрия w_m на 300 м | несход. h | несход. m |\n|---|---|---|---|---|---|---|---|---|")
    we = np.array([0, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 10])
    cv = []
    for a, b in zip(we[:-1], we[1:]):
        m = (D["w_star_over_u"] >= a) & (D["w_star_over_u"] < b)
        if m.sum() < 5:
            continue
        r = dict(lo=a, hi=b, n=int(m.sum()), du=float(np.median(D["dh_rms50_rel"][m])), dw=float(np.median(D["dw300_rms"][m])), skh=float(np.median(D["h_wskew300"][m])),
                 skm=float(np.median(D["m_wskew300"][m])), nch=float(nch[m].mean()), ncm=float(ncm[m].mean()))
        cv.append(r)
        T.append(f"| {a:g} | {b:g} | {r['n']} | {r['du']:.2f} | {r['dw']:.3f} | {r['skh']:.2f} | {r['skm']:.2f} | {r['nch']:.2f} | {r['ncm']:.2f} |")
    S["convective_by_wsu"] = cv
    # ветер слабый: несходимость vs U10
    ue = np.array([0, 1, 1.5, 2, 2.5, 3, 4, 5, 7, 9, 13])
    bu = binned_rate(D["u10_m_s"], ncm, ue)
    buh = binned_rate(D["u10_m_s"], nch, ue)
    T.append("\n### Несходимость по U10\n\n| U10 от | до | n | m | h |\n|---|---|---|---|---|")
    for a, b, nn, pm, ph in zip(ue[:-1], ue[1:], bu[2], bu[1], buh[1]):
        T.append(f"| {a:g} | {b:g} | {int(nn)} | {fmt(pm)} | {fmt(ph)} |")
    S["nonconv_by_u10"] = dict(edges=ue.tolist(), m=bu[1].tolist(), h=buh[1].tolist(), n=bu[2].tolist())
    # при одинаковом U10 — зависит ли от Fr? (U10 2–4 м/с)
    T.append("\n### При U10 = 2–4 м/с: несходимость по Fr (отделить «слабый ветер» от «блокирование»)\n\n| Fr от | до | n | m |\n|---|---|---|---|")
    mu = (D["u10_m_s"] >= 2) & (D["u10_m_s"] < 4)
    bb = binned_rate(fr[mu], ncm[mu], np.array([0.03, 0.15, 0.3, 0.5, 0.75, 1, 1.5, 3, 1000]))
    for a, b, nn, pm in zip([0.03, 0.15, 0.3, 0.5, 0.75, 1, 1.5, 3], [0.15, 0.3, 0.5, 0.75, 1, 1.5, 3, 1000], bb[2], bb[1]):
        T.append(f"| {a:g} | {b:g} | {int(nn)} | {fmt(pm)} |")
    S["nonconv_fr_at_u10_2_4"] = dict(frac=bb[1].tolist(), n=bb[2].tolist())
    T.append("\n### При Fr = 0,3–1: несходимость по U10\n\n| U10 от | до | n | m |\n|---|---|---|---|")
    mf = (fr >= 0.3) & (fr < 1)
    bb2 = binned_rate(D["u10_m_s"][mf], ncm[mf], ue)
    for a, b, nn, pm in zip(ue[:-1], ue[1:], bb2[2], bb2[1]):
        T.append(f"| {a:g} | {b:g} | {int(nn)} | {fmt(pm)} |")
    S["nonconv_u10_at_fr_03_1"] = dict(frac=bb2[1].tolist(), n=bb2[2].tolist())
    # N-зависимость: несходимость по N при U10 2–4
    T.append("\n### При U10 = 2–4 м/с: несходимость по N (устойчивость свободной атмосферы)\n\n| N, 1/с от | до | n | m |\n|---|---|---|---|")
    ne = np.array([0, 0.004, 0.007, 0.009, 0.011, 0.013, 0.02])
    bn = binned_rate(D["n_bv_s"][mu], ncm[mu], ne)
    for a, b, nn, pm in zip(ne[:-1], ne[1:], bn[2], bn[1]):
        T.append(f"| {a:g} | {b:g} | {int(nn)} | {fmt(pm)} |")
    S["nonconv_N_at_u10_2_4"] = dict(frac=bn[1].tolist(), n=bn[2].tolist())
    # --- G (охлаждение), h/z_i, час
    T.append("\n### Охлаждение (G): случаи с H_mean < 0 против H_mean > 0 при U10 < 3 м/с\n\n| группа | n | несход. m | несход. h | медиана разброса h (несош.), м/с | медиана h_stag25 | медиана h_rev25 |\n|---|---|---|---|---|---|---|")
    gstat = {}
    for lab, m in (("H < 0 (вечер)", (D["H_mean"] < 0) & (D["u10_m_s"] < 3)), ("H > 50 (день)", (D["H_mean"] > 50) & (D["u10_m_s"] < 3)), ("H < 0, все U", D["H_mean"] < 0)):
        nh = D["status_h"][m] != 0
        r = dict(n=int(m.sum()), ncm=float(ncm[m].mean()), nch=float(nch[m].mean()), sp=float(np.median(D["spread_h"][m][nh])) if nh.any() else np.nan,
                 stag=float(np.median(D["h_stag25"][m])), rev=float(np.median(D["h_rev25"][m])))
        gstat[lab] = r
        T.append(f"| {lab} | {r['n']} | {r['ncm']:.2f} | {r['nch']:.2f} | {fmt(r['sp'])} | {r['stag']:.3f} | {r['rev']:.3f} |")
    S["cooling"] = gstat
    T.append("\n### Δh/z_i: несходимость (m) по Fr для рельефа ниже и выше верха слоя\n\n| Fr от | до | Δh/z_i < 1 (n) | Δh/z_i ≥ 1 (n) |\n|---|---|---|---|")
    fe3 = np.array([0.03, 0.15, 0.3, 0.5, 0.75, 1, 1.5, 3, 1000])
    hz = []
    for a, b in zip(fe3[:-1], fe3[1:]):
        m = (fr >= a) & (fr < b)
        cells = [(float(ncm[m & mm].mean()) if (m & mm).any() else np.nan, int((m & mm).sum())) for mm in (hzi < 1, hzi >= 1)]
        hz.append(dict(lo=a, hi=b, cells=cells))
        T.append(f"| {a:g} | {b:g} | " + " | ".join(f"{fmt(c[0])} ({c[1]})" for c in cells) + " |")
    S["nonconv_by_hzi"] = hz
    T.append("\n### Класс часа: несходимость и оси\n\n| час | n | несход. m | несход. h | медиана Fr | медиана w*/U | медиана −z_i/L | медиана H | доля H_mean < 0 |\n|---|---|---|---|---|---|---|---|---|")
    hcls = {}
    for lab, m in (("утро 7–10", D["hour_local"] < 11), ("день 11–16", (D["hour_local"] >= 11) & (D["hour_local"] < 17)), ("вечер 17–20", D["hour_local"] >= 17)):
        r = dict(n=int(m.sum()), ncm=float(ncm[m].mean()), nch=float(nch[m].mean()), fr=float(np.median(fr[m])), wsu=float(np.median(D["w_star_over_u"][m])),
                 ziL=float(np.median(D["zi_over_L"][m])), H=float(np.median(D["H_mean"][m])), hneg=float((D["H_mean"][m] < 0).mean()))
        hcls[lab] = r
        T.append(f"| {lab} | {r['n']} | {r['ncm']:.2f} | {r['nch']:.2f} | {r['fr']:.2f} | {r['wsu']:.3f} | {r['ziL']:.1f} | {r['H']:.0f} | {r['hneg']:.2f} |")
    S["by_hour_class"] = hcls
    # «почти сошлось»: несошедшиеся с разбросом < 0,05 м/с (численная недоводка) против блуждания
    nc = ~ok
    S["nonconv_small_spread_frac"] = float((D["spread_m"][nc] < 0.05).mean())
    S["nonconv_small_spread_by_fr"] = [[float(a), float(b), float((D["spread_m"][nc & (fr >= a) & (fr < b)] < 0.05).mean()) if (nc & (fr >= a) & (fr < b)).any() else None]
                                       for a, b in zip(fe3[:-1], fe3[1:])]
    T.append(f"\nНесошедшиеся с разбросом поздних итераций < 0,05 м/с («почти сошлось»): {S['nonconv_small_spread_frac']:.2f} от всех несошедшихся m; по Fr: " +
             "; ".join(f"{a:g}–{b:g}: {fmt(v)}" for a, b, v in S["nonconv_small_spread_by_fr"]) + ".\n")
    # время счёта
    S["seconds_per_case"] = dict(mean=float(D["seconds"].mean()), median=float(np.median(D["seconds"])), p90=float(np.percentile(D["seconds"], 90)))
    T.append(f"\nВремя воркера на случай (оба решения): медиана {S['seconds_per_case']['median']:.1f} с, среднее {S['seconds_per_case']['mean']:.1f}, p90 {S['seconds_per_case']['p90']:.1f}.\n")

    # ------------------------------------------------------------------ рисунки
    c1, c2, c3 = "#1f77b4", "#d62728", "#2ca02c"
    # 1. несходимость по Fr: m, h + терцили
    fig, ax = plt.subplots(1, 3, figsize=(13, 3.8))
    ax[0].errorbar(bm[0], bm[1], yerr=[np.maximum(bm[1] - bm[3], 0), np.maximum(bm[4] - bm[1], 0)], fmt="o-", color=c1, label="без нагрева (m)", ms=3)
    ax[0].errorbar(bh[0], bh[1], yerr=[np.maximum(bh[1] - bh[3], 0), np.maximum(bh[4] - bh[1], 0)], fmt="s--", color=c2, label="с нагревом (h)", ms=3)
    xx = np.linspace(-1.7, 2, 200)
    ax[0].plot(10 ** xx, 1 / (1 + np.exp(-k * (xx - x0))), ":", color="k", label=f"сигмоида: Fr₅₀={10 ** x0:.2f}, ширина {wd:.1f} дек.")
    ax[0].set_xscale("log"); ax[0].set_xlabel("Fr = U_sat / (N·Δh)"); ax[0].set_ylabel("доля несошедшихся (1000 итераций)"); ax[0].legend(fontsize=7); ax[0].set_title("Пикар vs Fr")
    for axi, (key, label) in zip(ax[1:], (("w_star_over_u", "w*/U"), ("slope_p95_deg_100", "уклон p95, °"))):
        res, edges = tercile_curves(key, label)
        for (lab, b), col in zip(res, (c1, c3, c2)):
            axi.errorbar(b[0], b[1], yerr=[np.maximum(b[1] - b[3], 0), np.maximum(b[4] - b[1], 0)], fmt="o-", ms=3, color=col, label=lab)
        axi.set_xscale("log"); axi.set_xlabel("Fr"); axi.legend(fontsize=7); axi.set_title(f"терцили {label}")
    for a_ in ax:
        a_.set_ylim(0, 0.8)
    fig.tight_layout(); fig.savefig(out / f"fig_nonconv_fr_{tag}.png", dpi=130); plt.close(fig)

    # 2. критическое замедление
    fig, ax = plt.subplots(1, 3, figsize=(13, 3.8))
    cx = [np.sqrt(r["lo"] * r["hi"]) for r in crit]
    ax[0].plot(cx, [r["it_med"] for r in crit], "o-", color=c1, label="медиана")
    ax[0].plot(cx, [r["it_p90"] for r in crit], "s--", color=c1, alpha=0.6, label="p90")
    ax[0].set_xscale("log"); ax[0].set_xlabel("Fr"); ax[0].set_ylabel("итераций до сходимости (m, сошедшиеся)"); ax[0].legend(fontsize=7); ax[0].set_title("Критическое замедление")
    ax[1].plot(cx, [r["sp_med"] for r in crit], "o-", color=c2, label="медиана")
    ax[1].plot(cx, [r["sp_p90"] for r in crit], "s--", color=c2, alpha=0.6, label="p90")
    ax[1].set_xscale("log"); ax[1].set_xlabel("Fr"); ax[1].set_ylabel("p90 разброса поздних итераций на 60 м, м/с"); ax[1].legend(fontsize=7); ax[1].set_title("Несошедшиеся: амплитуда блуждания")
    sc = ax[2].scatter(fr[~ok], D["spread_m"][~ok] / np.maximum(D["u10_m_s"][~ok], 0.1), c=np.log10(np.maximum(D["w_star_over_u"][~ok], 1e-2)), s=6, cmap="viridis")
    ax[2].set_xscale("log"); ax[2].set_yscale("log"); ax[2].set_xlabel("Fr"); ax[2].set_ylabel("разброс / U10"); ax[2].set_title("Несошедшиеся: разброс/U10 (цвет — log w*/U)")
    plt.colorbar(sc, ax=ax[2])
    fig.tight_layout(); fig.savefig(out / f"fig_slowing_{tag}.png", dpi=130); plt.close(fig)

    # 3. параметры порядка
    fig, ax = plt.subplots(2, 3, figsize=(13, 7.2))
    ox = [np.sqrt(r["lo"] * r["hi"]) for r in op]
    for key, lab, col in (("stag", "застой (< 0,3 притока)", c1), ("turn", "поворот > 45°", c3), ("rev", "обратное течение", c2)):
        ax[0, 0].plot(ox, [r[key] for r in op], "o-", color=col, label=lab)
    ax[0, 0].set_xscale("log"); ax[0, 0].set_xlabel("Fr"); ax[0, 0].set_ylabel("доля клеток на 25 м (медиана)"); ax[0, 0].legend(fontsize=7); ax[0, 0].set_title("Блокирование/обход у земли")
    ax[0, 1].plot(ox, [r["speed"] for r in op], "o-", color=c1, label="средняя / приток")
    ax[0, 1].plot(ox, [r["speedup"] for r in op], "s--", color=c2, label="p99 / приток (50 м)")
    ax[0, 1].set_xscale("log"); ax[0, 1].set_xlabel("Fr"); ax[0, 1].legend(fontsize=7); ax[0, 1].set_title("Торможение и разгон")
    ax[0, 2].plot(ox, [r["wstd600_rel"] for r in op], "o-", color=c1, label="σ_w(600 м)/U_sat")
    ax[0, 2].set_xscale("log"); ax[0, 2].set_xlabel("Fr"); ax[0, 2].legend(fontsize=7); ax[0, 2].set_title("Волновая амплитуда")
    sx = [0.5 * (r["lo"] + r["hi"]) for r in sl]
    ax[1, 0].plot(sx, [r["rev_med"] for r in sl], "o-", color=c2, label="медиана"); ax[1, 0].plot(sx, [r["rev_p90"] for r in sl], "s--", color=c2, alpha=0.6, label="p90")
    ax[1, 0].axvline(16.7, color="k", ls=":", label="уклон 0,3 (16,7°)")
    ax[1, 0].set_xlabel("уклон p95 на 100 м, °"); ax[1, 0].set_ylabel("доля обратного течения на 25 м"); ax[1, 0].legend(fontsize=7); ax[1, 0].set_title("Срыв vs крутизна (Fr > 1,5)")
    wx = [0.5 * (r["lo"] + r["hi"]) for r in cv]
    ax[1, 1].plot(wx, [r["du"] for r in cv], "o-", color=c1, label="СКО Δu_h(50 м)/приток")
    ax[1, 1].plot(wx, [r["dw"] for r in cv], "s--", color=c2, label="СКО Δw(300 м), м/с")
    ax[1, 1].set_xlabel("w*/U"); ax[1, 1].legend(fontsize=7); ax[1, 1].set_title("Конвективная добавка h − m")
    ax[1, 2].plot(wx, [r["skh"] for r in cv], "o-", color=c2, label="с нагревом"); ax[1, 2].plot(wx, [r["skm"] for r in cv], "s--", color=c1, label="без нагрева")
    ax[1, 2].set_xlabel("w*/U"); ax[1, 2].set_ylabel("асимметрия w на 300 м"); ax[1, 2].legend(fontsize=7); ax[1, 2].set_title("Асимметрия w (термики?)")
    fig.tight_layout(); fig.savefig(out / f"fig_order_{tag}.png", dpi=130); plt.close(fig)

    # 4. карта случаев по осям
    fig, ax = plt.subplots(1, 3, figsize=(13, 4))
    wsu = np.maximum(D["w_star_over_u"], 3e-3)
    for m, col, lab in ((ok, c1, "сошлось"), (~ok, c2, "не сошлось")):
        ax[0].scatter(fr[m], wsu[m], s=4, color=col, alpha=0.4, label=lab)
    ax[0].set_xscale("log"); ax[0].set_yscale("log"); ax[0].set_xlabel("Fr"); ax[0].set_ylabel("w*/U"); ax[0].legend(fontsize=7, markerscale=3); ax[0].set_title("Случаи SY-12 в (Fr, w*/U)")
    for v in (0.3, 0.5, 1.0):
        ax[0].axvline(v, color="k", ls=":", lw=0.8)
    for m, col, lab in ((ok, c1, "сошлось"), (~ok, c2, "не сошлось")):
        ax[1].scatter(D["u10_m_s"][m], np.maximum(D["hs_w_m2"][m], 0.5), s=4, color=col, alpha=0.4, label=lab)
    uu = np.linspace(0.5, 12, 50)
    for cst, lab in ((2.0, "−z_i/L ≈ 5 (z_i=1,5 км)"), (10.0, "−z_i/L ≈ 25")):
        # −z_i/L = κ g/θ0 · H/(ρc_p) z_i / u*³, u* = 0,087 U10 → H = X·u*³ ρc_p θ0/(κ g z_i)
        us = KAPPA * uu / np.log(10 / Z0)
        Hc = cst * 5 * us ** 3 * RHO_CP * TH0 / (KAPPA * G * 1500.0)
        ax[1].plot(uu, Hc, "k:", lw=0.8)
        ax[1].text(uu[-1], Hc[-1], lab, fontsize=6, ha="right", va="bottom")
    ax[1].set_yscale("log"); ax[1].set_xlabel("U10, м/с"); ax[1].set_ylabel("H, Вт/м² (среднее по области)"); ax[1].set_title("Случаи в (U, H); пунктир — H ∝ U³"); ax[1].legend(fontsize=7, markerscale=3)
    ax[2].hist2d(np.log10(fr), np.log10(np.maximum(hzi, 1e-2)), bins=30, cmap="Greys")
    ax[2].set_xlabel("log₁₀ Fr"); ax[2].set_ylabel("log₁₀ Δh/z_i"); ax[2].set_title("Плотность случаев (Fr, Δh/z_i)")
    fig.tight_layout(); fig.savefig(out / f"fig_cases_{tag}.png", dpi=130); plt.close(fig)
    return S, T


def local_phase_example(solve_dir, cond_dir, out, which=0):
    """Карта фаз местности для одного случая: местный Fr (по местному перепаду в окне 4,4 км), уклон, нагрев → класс клетки.
    Механические фазы (A/B/C/D) и тепловые (нейтрально/E/F/G) — две отдельные карты: это две оси, а не одна."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import ListedColormap
    from scipy.ndimage import maximum_filter
    parts = sorted(glob.glob(os.path.join(solve_dir, "part-*.h5")))
    ct = np.concatenate([h5py.File(p, "r")["conditions/table"][:] for p in sorted(glob.glob(os.path.join(cond_dir, "part-*.h5")))])
    cmap = {(int(r["relief_id"]), int(r["cond_id"])): r for r in ct}
    with h5py.File(parts[0], "r") as f:
        cases = f["cases"][:]
        def ok(c):
            r = cmap[(int(c["relief_id"]), int(c["cond_id"]))]
            return 0.4 < r["froude"] < 1.0 and r["hs_w_m2"] > 80 and r["n_bv_s"] > 0.008 and 3 < r["u10_m_s"] < 7
        cand = [j for j, c in enumerate(cases) if ok(c)]
        j = cand[which] if cand else 0
        c = cases[j]
        cr = cmap[(int(c["relief_id"]), int(c["cond_id"]))]
        hc = np.asarray(f["inputs/hc"][j], float)
        H = np.asarray(f["inputs/heat_flux"][j], float)
        fm = np.asarray(f["fields/m"][j], np.float32)
    u10, alpha, mp, N = float(cr["u10_m_s"]), float(cr["alpha"]), float(cr["max_profile"]), float(cr["n_bv_s"])
    U = u10 * mp
    loc = maximum_filter(hc, 11) - hc           # местный «гребень над клеткой» в окне 4,4 км
    fr_loc = U / (max(N, 1e-4) * np.maximum(loc, 30.0))
    gy, gx = np.gradient(hc, DX)
    slope = np.hypot(gx, gy)
    phi = np.radians(float(cr["wind_from_deg"]))
    e = (-np.sin(phi), -np.cos(phi))
    lee = (gx * e[0] + gy * e[1]) < 0           # склон падает по ветру (подветренный)
    us = KAPPA * u10 / np.log(10 / Z0)
    zi = max(float(cr["z_i_m"]) - hc.mean(), 100.0)
    ziL = KAPPA * G / TH0 * np.maximum(H, 0) / RHO_CP * zi / max(us, 1e-3) ** 3
    mech = np.full(hc.shape, 0)                 # 0 A вынужденное обтекание
    mech[(fr_loc < 1.5) & (fr_loc >= 0.5)] = 2  # C критическая зона
    mech[fr_loc < 0.5] = 3                      # D блокирование
    mech[(mech == 0) & (slope > 0.3) & lee] = 1 # B срыв (на 400 м уклон > 0,3 редок)
    therm = np.full(hc.shape, 0)                # 0 нейтрально/слабый нагрев
    therm[(ziL > 5) & (ziL <= 25)] = 1          # E конвекция с ветром
    therm[ziL > 25] = 2                         # F свободная конвекция
    therm[H < -5] = 3                           # G охлаждение
    mn = ["A обтекание", "B срыв", "C Fr~1", "D блокирование"]
    tn = ["нейтр./слабый нагрев", "E конв.+ветер", "F своб. конв.", "G охлаждение"]
    cm_m = ListedColormap(["#9ecae1", "#e6550d", "#fdae6b", "#3182bd"])
    cm_t = ListedColormap(["#eeeeee", "#a1d99b", "#31a354", "#756bb1"])
    fig, ax = plt.subplots(1, 5, figsize=(18, 3.9))
    im = ax[0].imshow(hc, origin="lower", cmap="terrain"); ax[0].set_title(f"рельеф, случай {int(c['case'])} (relief {int(c['relief_id'])})"); plt.colorbar(im, ax=ax[0])
    im = ax[1].imshow(np.log10(np.clip(fr_loc, 0.03, 30)), origin="lower", cmap="RdBu", vmin=-1.5, vmax=1.5)
    ax[1].set_title(f"log₁₀ местного Fr (U_sat={U:.1f} м/с, N={N:.4f} 1/с)"); plt.colorbar(im, ax=ax[1])
    im = ax[2].imshow(mech, origin="lower", cmap=cm_m, vmin=-0.5, vmax=3.5); ax[2].set_title("механические фазы (черновые пороги)")
    cb = plt.colorbar(im, ax=ax[2], ticks=range(4)); cb.ax.set_yticklabels(mn, fontsize=7)
    im = ax[3].imshow(therm, origin="lower", cmap=cm_t, vmin=-0.5, vmax=3.5); ax[3].set_title(f"тепловые фазы (−z_i/L по H клетки; H ср. {H.mean():.0f} Вт/м²)")
    cb = plt.colorbar(im, ax=ax[3], ticks=range(4)); cb.ax.set_yticklabels(tn, fontsize=7)
    sp = np.hypot(fm[0, 0], fm[1, 0])
    im = ax[4].imshow(sp / max(inflow_speed(u10, alpha, mp, 25), 0.1), origin="lower", cmap="viridis", vmin=0, vmax=1.5); ax[4].set_title("решатель m: |u|(25 м)/приток"); plt.colorbar(im, ax=ax[4])
    for a_ in ax:
        a_.set_xticks([]); a_.set_yticks([])
    fig.tight_layout(); fig.savefig(out / "fig_local_phase.png", dpi=130); plt.close(fig)
    fm_ = {mn[i]: float((mech == i).mean()) for i in range(4)}
    ft_ = {tn[i]: float((therm == i).mean()) for i in range(4)}
    # связь: застой у земли в решателе по механическим классам
    rel = sp / max(inflow_speed(u10, alpha, mp, 25), 0.1)
    stag_by = {mn[i]: float((rel[mech == i] < 0.3).mean()) if (mech == i).any() else None for i in range(4)}
    return dict(case=int(c["case"]), relief_id=int(c["relief_id"]), fr=float(cr["froude"]), u10=u10, U_sat=U, N=N, H_mean=float(H.mean()), zi_agl=zi,
                mech_fractions=fm_, therm_fractions=ft_, stagnant_frac_by_mech_class=stag_by)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--solve", default=str(DATA / "solve/hg_v2__hgw24__s0-939a467"))
    ap.add_argument("--conditions", default=str(DATA / "conditions/hg_v2_hgw24"))
    ap.add_argument("--relief", default=str(DATA / "real/hg_v2"))
    ap.add_argument("--game-solve", default=str(DATA / "solve/game2__hgw24__s0-939a467"))
    ap.add_argument("--game-conditions", default=str(DATA / "conditions/game2_hgw24"))
    ap.add_argument("--game-relief", default=str(DATA / "real/game_hg2"))
    ap.add_argument("--out", default=str(HERE / "out"))
    ap.add_argument("--recompute", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args(argv)
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    cache = out / "per_case.npz"
    if cache.exists() and not a.recompute:
        D = dict(np.load(cache))
    else:
        D = compute(a.solve, a.conditions, a.relief, a.limit or None)
        np.savez_compressed(cache, **D)
    S, T = analyse(D, out, "hg")
    S["local_phase_example"] = local_phase_example(a.solve, a.conditions, out)
    if os.path.isdir(a.game_solve):
        gc = out / "per_case_game.npz"
        Dg = dict(np.load(gc)) if gc.exists() and not a.recompute else compute(a.game_solve, a.game_conditions, a.game_relief)
        np.savez_compressed(gc, **Dg)
        Sg, Tg = analyse(Dg, out, "game")
        S["game"] = {k: Sg[k] for k in ("n", "nonconv_m", "nonconv_h", "nonconv_both", "sigmoid_fr_m", "q_froude", "q_w_star_over_u")}
        T += ["\n# Места игры (game2, 96 случаев)\n"] + Tg[:3]
    (out / "tables.md").write_text("# air-phase: таблицы по SY-12 (hg_v2, hgw24)\n\n" + "\n".join(T) + "\n", encoding="utf-8")
    json.dump(S, open(out / "summary.json", "w"), indent=1, ensure_ascii=False, default=float)
    print(json.dumps({k: S[k] for k in ("n", "nonconv_m", "nonconv_h", "nonconv_both", "sigmoid_fr_m", "separability")}, ensure_ascii=False, indent=1, default=float))


if __name__ == "__main__":
    main()
