#!/usr/bin/env python3
"""AP-7: разные ли оси Fr и слабый ветер (air_phase.md §5.2) — разбор серии FIXED_U (план ap_v2).

Одна команда, только CPU, данные только читаются:
  PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
  $PY tools/research/air_phase/analysis/AP-7/run.py
Вход: $AIR_SYNTH_DATA/phase/{ap_v2, ap_v2__s1-74644c4, ap_v1, ap_v1__s1-74644c4} (P2, P3),
      tools/research/air_phase/out/per_case.npz (SY-12, признаки phase_stats),
      $AIR_SYNTH_DATA/phase/features_ap_v2.h5 (P6 v2, метрики слоёв AP-6; нет — раздел пропускается).
Выход: summary.json, tables.md, fig_*.png рядом со скриптом.
"""
import glob
import json
import os
import sys

import h5py
import numpy as np
from scipy.optimize import curve_fit

HERE = os.path.dirname(os.path.abspath(__file__))
AP = os.path.dirname(os.path.dirname(HERE))  # tools/research/air_phase
D = os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data"))
V2_PLAN, V2_RES = f"{D}/phase/ap_v2", f"{D}/phase/ap_v2__s1-74644c4"
V1_PLAN, V1_RES = f"{D}/phase/ap_v1", f"{D}/phase/ap_v1__s1-74644c4"
NEAR = 0.05  # м/с: «почти сошлось» (late_spread60_p90 при статусе max), как §5.2
ORDER = ["f_turn25", "f_rev25", "f_stag25", "f_speed25", "f_wstd600"]
rng = np.random.default_rng(7)
OUT = {}
TAB = []


def tab(title, header, rows):
    TAB.append(f"\n### {title}\n\n| " + " | ".join(header) + " |\n|" + "---|" * len(header) + "\n"
               + "\n".join("| " + " | ".join(str(x) for x in r) + " |" for r in rows) + "\n")


def f3(x):
    return "—" if x is None or (isinstance(x, float) and not np.isfinite(x)) else f"{x:.3g}"


# ---------------------------------------------------------------- данные ap_v2
def load_v2():
    plan = json.load(open(f"{V2_PLAN}/plan.json"))
    sel = {s["line_id"]: s for s in plan["fixed_u_selection"]}
    rows = []
    for fn in sorted(glob.glob(f"{V2_RES}/part-*.h5")):
        with h5py.File(fn, "r") as f:
            c, o = f["cases"][:], f["order"][:]
            for i in range(len(c)):
                s = sel[int(c["line_id"][i])]
                r = {k: float(c[k][i]) for k in ("fr", "u10", "u_sat", "n_bv", "z_i_agl_m", "heat_flux_wm2",
                                                  "late_spread60_p90", "zi_over_L")}
                r.update(case_id=int(c["case_id"][i]), status=int(c["status"][i]), iters=int(c["iters"][i]),
                         shape=s["shape"], H=float(s["H"]), variant=s["variant"], h=float(s["h_m"]))
                r.update({k: float(o[k][i]) for k in ORDER})
                rows.append(r)
    rows.sort(key=lambda r: r["case_id"])
    assert len(rows) == int(plan["n_cases"]), (len(rows), plan["n_cases"])
    a = {k: np.array([r[k] for r in rows]) for k in rows[0]}
    a["nc"] = (a["status"] != 0).astype(float)
    a["near"] = ((a["status"] == 1) & (a["late_spread60_p90"] < NEAR)).astype(float)
    a["wstd600_rel"] = a["f_wstd600"] / a["u_sat"]
    return a


def load_v1_grid():
    plan = json.load(open(f"{V1_PLAN}/plan.json"))
    rel = {r["relief_id"]: r for r in plan["reliefs"]}
    keep = []
    for fn in sorted(glob.glob(f"{V1_RES}/part-*.h5")):
        with h5py.File(fn, "r") as f:
            c = f["cases"][:]
            c = c[c["series"] == 1]
            if len(c):
                keep.append(c)
    c = np.concatenate(keep)
    shape = np.array([rel[int(i)]["shape"].lower() for i in c["relief_id"]])
    slope = np.array([rel[int(i)]["slope"] for i in c["relief_id"]])
    h = np.array([rel[int(i)]["h_m"] for i in c["relief_id"]])
    hzi = h / c["z_i_agl_m"]
    m = (np.isclose(slope, 0.3)) & (np.isclose(hzi, 1.0, rtol=0.02)) & np.isin(shape, ["ridge", "hill"]) \
        & np.isin(np.round(c["heat_flux_wm2"]), [0, 250])
    c, shape = c[m], shape[m]
    return dict(fr=c["fr"].astype(float), u_sat=c["u_sat"].astype(float), u10=c["u10"].astype(float),
                n_bv=c["n_bv"].astype(float), H=np.round(c["heat_flux_wm2"]).astype(float), shape=shape,
                nc=(c["status"] != 0).astype(float), status=c["status"].astype(int), iters=c["iters"].astype(int),
                spread=c["late_spread60_p90"].astype(float), h=np.full(len(c), 500.0))


# ---------------------------------------------------------------- логистическая регрессия
def logit_fit(X, y, lam=0.0):
    """IRLS; X — без столбца единиц; лёгкий L2 (lam) на стандартизованные коэффициенты (не на свободный член)."""
    mu, sd = X.mean(0), X.std(0) + 1e-12
    Z = np.column_stack([np.ones(len(y)), (X - mu) / sd])
    b = np.zeros(Z.shape[1])
    P = lam * np.eye(Z.shape[1]); P[0, 0] = 0
    for _ in range(200):
        p = 1 / (1 + np.exp(-np.clip(Z @ b, -30, 30)))
        W = p * (1 - p) + 1e-9
        g = Z.T @ (y - p) - P @ b
        Hm = (Z * W[:, None]).T @ Z + P
        step = np.linalg.solve(Hm, g)
        b += step
        if np.abs(step).max() < 1e-8:
            break
    p = np.clip(1 / (1 + np.exp(-(Z @ b))), 1e-12, 1 - 1e-12)
    dev = -2 * np.sum(y * np.log(p) + (1 - y) * np.log(1 - p))
    braw = b[1:] / sd
    return dict(b_std=b[1:], b_raw=braw, b0=b[0] - np.sum(braw * mu), dev=dev, p=p)


def cv_logloss(X, y, lam, k=10, reps=20):
    n = len(y); ll = []; acc = []
    for _ in range(reps):
        idx = rng.permutation(n)
        for j in range(k):
            te = idx[j::k]; tr = np.setdiff1d(idx, te)
            f = logit_fit(X[tr], y[tr], lam)
            p = 1 / (1 + np.exp(-np.clip(f["b0"] + X[te] @ f["b_raw"], -30, 30)))
            p = np.clip(p, 1e-6, 1 - 1e-6)
            ll += list(-(y[te] * np.log(p) + (1 - y[te]) * np.log(1 - p)))
            acc += list(((p > 0.5) == (y[te] > 0.5)).astype(float))
    return float(np.mean(ll)), float(np.mean(acc))


def regressions(name, feats, y, models, lam, reps=20):
    res = {}
    rows = []
    for mname, keys in models.items():
        X = np.column_stack([feats[k] for k in keys])
        f = logit_fit(X, y, lam)
        ll, acc = cv_logloss(X, y, lam, reps=reps)
        res[mname] = dict(features=keys, coef_std=dict(zip(keys, map(float, f["b_std"]))),
                          coef_raw=dict(zip(keys, map(float, f["b_raw"]))), deviance=float(f["dev"]),
                          aic=float(f["dev"] + 2 * (len(keys) + 1)), cv_logloss=ll, cv_accuracy=acc)
        rows.append([mname, ", ".join(f"{k} {v:+.2f} ({res[mname]['coef_raw'][k]:+.2f})" for k, v in res[mname]["coef_std"].items()),
                     f"{f['dev']:.1f}", f"{res[mname]['aic']:.1f}", f"{ll:.3f}", f"{acc:.3f}"])
    tab(f"{name}: логистическая регрессия несходимости (L2 λ = {lam} на стандартизованных; CV 10×20)",
        ["модель", "коэф. на 1 СКО (на единицу признака)", "девианс", "AIC", "CV log-loss", "CV точность"], rows)
    return res


# ---------------------------------------------------------------- сигмоида (модель §9 п. 6, P6 fit_sigmoid)
def sig(lx, lxc, w, y0, dy):
    return y0 + dy / (1 + np.exp(-(lx - lxc) / w))


def fit_sigmoid(x, y, n_boot=200):
    lx = np.log10(x)
    p0 = [np.median(lx), -0.1 if y[np.argmin(lx)] > y[np.argmax(lx)] else 0.1, y.min(), y.max() - y.min()]
    if p0[1] < 0:  # убывающая: y0 — верх, dy < 0, w > 0
        p0 = [np.median(lx), 0.1, y.max(), y.min() - y.max()]
    bounds = ([lx.min() - 1, 0.005, -np.inf, -np.inf], [lx.max() + 1, 2.0, np.inf, np.inf])

    def one(lx_, y_):
        try:
            p, _ = curve_fit(sig, lx_, y_, p0=p0, bounds=bounds, maxfev=20000)
            return p
        except Exception:
            return None
    p = one(lx, y)
    if p is None:
        return None
    bs = []
    for _ in range(n_boot):
        i = rng.integers(0, len(lx), len(lx))
        q = one(lx[i], y[i])
        if q is not None:
            bs.append(q)
    bs = np.array(bs)
    w_dec = 4.394 * p[1]  # 10–90 % в декадах = 2·ln 9·w
    return dict(x_c=float(10 ** p[0]), w=float(p[1]), w10_90_dec=float(w_dec), y0=float(p[2]), dy=float(p[3]),
                x_c_ci=[float(10 ** np.percentile(bs[:, 0], 5)), float(10 ** np.percentile(bs[:, 0], 95))],
                w10_90_ci=[float(4.394 * np.percentile(bs[:, 1], 5)), float(4.394 * np.percentile(bs[:, 1], 95))],
                n=int(len(x)))


# ---------------------------------------------------------------- разбор
def frbins():
    return [0.15, 0.25, 0.4, 0.6, 0.9, 1.4, 3.01]


def main():
    a = load_v2()
    n = len(a["nc"])
    OUT["n_cases"] = n
    OUT["n_ok"] = int((a["status"] == 0).sum()); OUT["n_max"] = int((a["status"] == 1).sum())
    OUT["n_div"] = int((a["status"] == 2).sum())
    OUT["u10_m_s_by_u_sat"] = {str(u): float(np.unique(np.round(a["u10"][a["u_sat"] == u], 3))[0]) for u in (3.0, 6.0)}

    # 1. несходимость по Fr при U_sat 3 и 6 отдельно (все формы/H/оси)
    bins = frbins(); rows = []; t1 = {}
    for u in (3.0, 6.0):
        for v in ("all", "n_axis", "h_axis"):
            for lo, hi in zip(bins[:-1], bins[1:]):
                m = (a["u_sat"] == u) & (a["fr"] >= lo) & (a["fr"] < hi) & ((a["variant"] == v) if v != "all" else True)
                if m.sum() == 0:
                    continue
                ncm = m & (a["nc"] > 0)
                sp = a["late_spread60_p90"][ncm]
                it = a["iters"][m & (a["status"] == 0)]
                rec = dict(n=int(m.sum()), nc_frac=float(a["nc"][m].mean()),
                           near_frac_of_nc=float(a["near"][ncm].mean()) if ncm.any() else None,
                           spread_nc_median_m_s=float(np.median(sp)) if len(sp) else None,
                           iters_ok_median=float(np.median(it)) if len(it) else None,
                           n_bv_range=[float(a["n_bv"][m].min()), float(a["n_bv"][m].max())],
                           h_m_range=[float(a["h"][m].min()), float(a["h"][m].max())])
                t1[f"u{u:g}_{v}_fr{lo:g}-{hi:g}"] = rec
                rows.append([f"{u:g}", v, f"{lo:g}–{hi:g}", rec["n"], f"{rec['nc_frac']:.2f}", f3(rec["near_frac_of_nc"]),
                             f3(rec["spread_nc_median_m_s"]), f3(rec["iters_ok_median"]),
                             f"{rec['n_bv_range'][0]:.4f}–{rec['n_bv_range'][1]:.4f}", f"{rec['h_m_range'][0]:.0f}–{rec['h_m_range'][1]:.0f}"])
    OUT["nonconv_by_fr"] = t1
    tab("Несходимость по Fr при фиксированном U_sat (все формы и H)",
        ["U_sat, м/с", "ось", "Fr", "n", "доля несх.", "«почти» среди несх.", "разброс несх., м/с (мед.)",
         "итераций сошедшихся (мед.)", "N, 1/с", "h, м"], rows)

    # 2. один и тот же Fr, два ветра: пары (форма, H, ось, Fr ±3 %)
    def pairs(key_a, key_b, cond_a, cond_b, match):
        ia = np.where(cond_a)[0]; ib = np.where(cond_b)[0]; out = []
        for i in ia:
            for j in ib:
                if all(a[k][i] == a[k][j] for k in match) and abs(np.log(a["fr"][i] / a["fr"][j])) < 0.03:
                    out.append((i, j))
        return out

    def ctab(pp, name, la, lb):
        x = np.array([[a["nc"][i], a["nc"][j]] for i, j in pp])
        r = dict(n_pairs=len(pp), both_ok=int(((x[:, 0] == 0) & (x[:, 1] == 0)).sum()),
                 both_nc=int(((x[:, 0] == 1) & (x[:, 1] == 1)).sum()),
                 only_a_nc=int(((x[:, 0] == 1) & (x[:, 1] == 0)).sum()),
                 only_b_nc=int(((x[:, 0] == 0) & (x[:, 1] == 1)).sum()), a=la, b=lb) if len(pp) else dict(n_pairs=0)
        return r

    pu = pairs("u3", "u6", a["u_sat"] == 3, a["u_sat"] == 6, ["shape", "H", "variant"])
    OUT["pairs_u3_vs_u6_same_fr"] = ctab(pu, "", "U_sat 3", "U_sat 6")
    OUT["pairs_u3_vs_u6_same_fr"]["fr_values"] = sorted(set(round(float(a["fr"][i]), 3) for i, _ in pu))
    pv = pairs("n", "h", a["variant"] == "n_axis", a["variant"] == "h_axis", ["shape", "H", "u_sat"])
    OUT["pairs_naxis_vs_haxis_same_fr_u"] = ctab(pv, "", "n_axis", "h_axis")
    # детали: где расходятся оси
    det = []
    for i, j in pv:
        if a["nc"][i] != a["nc"][j]:
            det.append([a["shape"][i], f"{a['H'][i]:g}", f"{a['u_sat'][i]:g}", f"{a['fr'][i]:.3f}",
                        f"N {a['n_bv'][i]:.4f}, h {a['h'][i]:.0f}: {'несх.' if a['nc'][i] else 'сошл.'} ({a['late_spread60_p90'][i]:.3f})",
                        f"N {a['n_bv'][j]:.4f}, h {a['h'][j]:.0f}: {'несх.' if a['nc'][j] else 'сошл.'} ({a['late_spread60_p90'][j]:.3f})"])
    tab("Пары «ось N против оси h» при одном Fr и U_sat, где сходимость разная (в скобках — разброс поздних итераций, м/с)",
        ["форма", "H", "U_sat", "Fr", "n_axis", "h_axis"], det)
    ph = pairs("H0", "H250", a["H"] == 0, a["H"] == 250, ["shape", "u_sat", "variant"])
    OUT["pairs_H0_vs_H250"] = ctab(ph, "", "H 0", "H 250")
    ps = pairs("ridge", "hill", a["shape"] == "ridge", a["shape"] == "hill", ["H", "u_sat", "variant"])
    OUT["pairs_ridge_vs_hill"] = ctab(ps, "", "ridge", "hill")
    rows = []
    for k in ("pairs_u3_vs_u6_same_fr", "pairs_naxis_vs_haxis_same_fr_u", "pairs_H0_vs_H250", "pairs_ridge_vs_hill"):
        r = OUT[k]
        rows.append([k, r["n_pairs"], r["both_ok"], r["both_nc"], f"{r['only_a_nc']} ({r['a']})", f"{r['only_b_nc']} ({r['b']})"])
    tab("Парные сравнения (одинаковые прочие условия)", ["сравнение", "пар", "обе сошлись", "обе нет", "несх. только a", "несх. только b"], rows)

    # 3. порог по N при фиксированном U_sat: max N сошедшихся и min N несошедшихся (по форме и H)
    rows = []; thr = {}
    for u in (3.0, 6.0):
        for sh in ("ridge", "hill"):
            for H in (0.0, 250.0):
                m = (a["u_sat"] == u) & (a["shape"] == sh) & (a["H"] == H)
                ok, bad = m & (a["nc"] == 0), m & (a["nc"] == 1)
                nmax_ok = float(a["n_bv"][ok].max()) if ok.any() else None
                nmin_nc = float(a["n_bv"][bad].min()) if bad.any() else None
                # сколько случаев «не на своей стороне» порога по N (N_c — середина в лог)
                nc_ = np.sqrt(nmax_ok * nmin_nc) if (nmax_ok and nmin_nc) else None
                if nc_:
                    mis_n = int(((a["n_bv"][m] > nc_) != (a["nc"][m] == 1)).sum())
                else:
                    mis_n = None
                # то же для лучшего порога по Fr
                frs = np.sort(np.unique(a["fr"][m])); best = (10 ** 9, None)
                for fc in np.sqrt(frs[1:] * frs[:-1]):
                    e = int(((a["fr"][m] < fc) != (a["nc"][m] == 1)).sum())
                    if e < best[0]:
                        best = (e, float(fc))
                ns = np.sort(np.unique(a["n_bv"][m])); bestn = (10 ** 9, None)
                for c_ in np.sqrt(ns[1:] * ns[:-1]):
                    e = int(((a["n_bv"][m] > c_) != (a["nc"][m] == 1)).sum())
                    if e < bestn[0]:
                        bestn = (e, float(c_))
                thr[f"u{u:g}_{sh}_H{H:g}"] = dict(n=int(m.sum()), n_max_ok=nmax_ok, n_min_nc=nmin_nc,
                                                  n_crit_best=bestn[1], errors_n_threshold=bestn[0],
                                                  fr_crit_best=best[1], errors_fr_threshold=best[0],
                                                  u_over_ncrit_m=(u / bestn[1]) if bestn[1] else None)
                rows.append([f"{u:g}", sh, f"{H:g}", int(m.sum()), f3(nmax_ok), f3(nmin_nc), f3(bestn[1]), bestn[0],
                             f3(best[1]), best[0], f3(u / bestn[1]) if bestn[1] else "—"])
    OUT["thresholds"] = thr
    tab("Один порог: по N (несх. при N > N_c) против по Fr (несх. при Fr < Fr_c) — ошибок классификации",
        ["U_sat", "форма", "H", "n", "max N сошл.", "min N несх.", "N_c лучш.", "ошибок N", "Fr_c лучш.", "ошибок Fr", "U_sat/N_c, м"], rows)
    nc3 = [thr[k]["n_crit_best"] for k in thr if k.startswith("u3_") and k.endswith("_H0")]
    nc6 = [thr[k]["n_crit_best"] for k in thr if k.startswith("u6_") and k.endswith("_H0")]
    OUT["n_crit_H0_by_u_sat"] = {"3": float(np.exp(np.mean(np.log(nc3)))), "6": float(np.exp(np.mean(np.log(nc6))))}
    OUT["n_crit_exponent_vs_u_sat"] = float(np.log(np.exp(np.mean(np.log(nc6))) / np.exp(np.mean(np.log(nc3)))) / np.log(2))
    OUT["errors_total_n_threshold"] = int(sum(thr[k]["errors_n_threshold"] for k in thr))
    OUT["errors_total_fr_threshold"] = int(sum(thr[k]["errors_fr_threshold"] for k in thr))

    # 4. логистическая регрессия ap_v2
    feats = dict(logFr=np.log(a["fr"]), logU=np.log(a["u_sat"]), logN=np.log(a["n_bv"]), logh=np.log(a["h"]),
                 ridge=(a["shape"] == "ridge").astype(float), heat=(a["H"] > 0).astype(float),
                 logU_over_N=np.log(a["u_sat"] / a["n_bv"]))
    models = {"logFr": ["logFr"], "logU": ["logU"], "logFr+logU": ["logFr", "logU"],
              "logN": ["logN"], "logN+logU": ["logN", "logU"], "logN+logU+logh": ["logN", "logU", "logh"],
              "logU/N": ["logU_over_N"],
              "logN+logU+logh+ridge+heat": ["logN", "logU", "logh", "ridge", "heat"],
              "logFr+logU+ridge+heat": ["logFr", "logU", "ridge", "heat"]}
    OUT["logit_ap_v2"] = regressions("ap_v2 (296)", feats, a["nc"], models, lam=0.3)
    h0 = a["H"] == 0
    f0 = {k: v[h0] for k, v in feats.items()}
    OUT["logit_ap_v2_H0"] = regressions("ap_v2, только H = 0 (148)", f0, a["nc"][h0],
                                        {k: v for k, v in models.items() if "heat" not in v}, lam=0.3)
    cr = OUT["logit_ap_v2_H0"]["logN+logU+logh"]["coef_raw"]
    OUT["H0_raw_coef_ratio_h_over_N"] = float(cr["logh"] / cr["logN"])   # = 1, если h и N входят только через Fr
    OUT["H0_raw_coef_ratio_U_over_N"] = float(cr["logU"] / cr["logN"])   # = −1 для Fr и для U/N
    # нагрев: конвективная несходимость там, где без нагрева сошлось бы (N < N_c(U), H = 0)
    wst = (9.81 / 300.0 * a["heat_flux_wm2"] / 1200.0 * a["z_i_agl_m"]).clip(0) ** (1 / 3)
    a["w_star"] = wst
    a["wstar_over_u10"] = wst / a["u10"]
    ncr = np.array([OUT["n_crit_H0_by_u_sat"][f"{u:g}"] for u in a["u_sat"]])
    sub = a["n_bv"] < ncr / 1.05
    rows = []; hh = {}
    for H in (0.0, 250.0):
        for lo, hi in ((0, 0.01), (0.01, 0.8), (0.8, 1.0), (1.0, 1.3), (1.3, 9)):
            m = sub & (a["H"] == H) & (a["wstar_over_u10"] >= lo) & (a["wstar_over_u10"] < hi)
            if m.any():
                hh[f"H{H:g}_wsu{lo:g}-{hi:g}"] = dict(n=int(m.sum()), nc_frac=float(a["nc"][m].mean()),
                                                     spread_nc_median=float(np.median(a["late_spread60_p90"][m & (a["nc"] > 0)])) if (m & (a["nc"] > 0)).any() else None)
                rows.append([f"{H:g}", f"{lo:g}–{hi:g}", int(m.sum()), f"{a['nc'][m].mean():.2f}",
                             f3(hh[f"H{H:g}_wsu{lo:g}-{hi:g}"]["spread_nc_median"]),
                             f"{a['u_sat'][m].min():g}–{a['u_sat'][m].max():g}", f"{a['z_i_agl_m'][m].min():.0f}–{a['z_i_agl_m'][m].max():.0f}"])
    OUT["heat_nonconv_below_ncrit"] = hh
    tab("Нагрев: несходимость в случаях N < N_c(U_sat) (без нагрева там сходится) по w*/U10; w* = (g/θ₀·H/(ρc_p)·z_i)^(1/3)",
        ["H, Вт/м²", "w*/U10", "n", "доля несх.", "разброс несх., м/с", "U_sat", "z_i, м"], rows)

    # 5. GRID ap_v1 (s = 0,3, h/z_i = 1): Fr сцеплен с ветром; сравнение и предсказание порога по N
    g = load_v1_grid()
    rows = []; gt = {}
    for lo, hi in zip([0.1, 0.15, 0.25, 0.4, 0.6, 0.9, 1.4, 2.5], [0.15, 0.25, 0.4, 0.6, 0.9, 1.4, 2.5, 5.01]):
        m = (g["fr"] >= lo) & (g["fr"] < hi)
        if m.any():
            gt[f"fr{lo:g}-{hi:g}"] = dict(n=int(m.sum()), nc_frac=float(g["nc"][m].mean()),
                                          u_sat_range=[float(g["u_sat"][m].min()), float(g["u_sat"][m].max())])
            rows.append([f"{lo:g}–{hi:g}", int(m.sum()), f"{g['nc'][m].mean():.2f}",
                         f"{g['u_sat'][m].min():.2f}–{g['u_sat'][m].max():.2f}", f"{g['u10'][m].min():.2f}–{g['u10'][m].max():.2f}"])
    OUT["grid_ap_v1_s03_hzi1"] = dict(n=int(len(g["nc"])), by_fr=gt)
    fg = fit_sigmoid(g["fr"], g["nc"])
    OUT["grid_ap_v1_s03_hzi1"]["sigmoid_nc_vs_fr"] = fg
    tab("GRID ap_v1 (s = 0,3, h/z_i = 1, хребет и холм, H 0/250; N = 0,01, h = 500: U_sat = 5·Fr)",
        ["Fr", "n", "доля несх.", "U_sat, м/с", "U10, м/с"], rows)
    # совпадение точек: GRID Fr 0,6 (U_sat 3) и Fr 1,2 (U_sat 6) ↔ h_axis U_sat 3/6 при h ≈ 500
    cmp_ = []
    for u, frg in ((3.0, 0.6), (6.0, 1.2)):
        mg = np.isclose(g["fr"], frg, atol=1e-3)
        mv = (a["u_sat"] == u) & (np.abs(a["h"] - 500) < 30) & (a["variant"] == "h_axis")
        cmp_.append(dict(u_sat=u, grid_fr=frg, grid_nc=float(g["nc"][mg].mean()), grid_n=int(mg.sum()),
                         v2_fr=float(np.mean(a["fr"][mv])), v2_nc=float(a["nc"][mv].mean()), v2_n=int(mv.sum())))
    OUT["grid_vs_v2_same_point"] = cmp_
    # предсказание границы GRID (N = 0,01, h = 500) по порогу N_c(U) из ap_v2 при H = 0: N_c(U_c) = 0,01
    nc = OUT["n_crit_H0_by_u_sat"]; p_ = OUT["n_crit_exponent_vs_u_sat"]
    u_c = 3.0 * (0.01 / nc["3"]) ** (1 / p_)
    m0 = g["H"] == 0
    frs = np.unique(g["fr"][m0]); best = (10 ** 9, None)
    for fc in np.sqrt(frs[1:] * frs[:-1]):
        e = int(((g["fr"][m0] < fc) != (g["nc"][m0] == 1)).sum())
        if e < best[0]:
            best = (e, float(fc))
    OUT["grid_boundary_prediction_H0"] = dict(u_sat_crit_pred=float(u_c), fr_crit_pred=float(u_c / (0.01 * 500)),
                                              fr_crit_grid_best=best[1], errors_grid_best=best[0], n=int(m0.sum()))
    # логистика по объединению: GRID (ось U при N, h фиксированных) + ap_v2 (оси N и h при U фикс.)
    al = dict(logFr=np.r_[feats["logFr"], np.log(g["fr"])], logU=np.r_[feats["logU"], np.log(g["u_sat"])],
              logN=np.r_[feats["logN"], np.log(g["n_bv"])], logh=np.r_[feats["logh"], np.log(g["h"])],
              ridge=np.r_[feats["ridge"], (g["shape"] == "ridge").astype(float)],
              heat=np.r_[feats["heat"], (g["H"] > 0).astype(float)])
    al["logU_over_N"] = al["logU"] - al["logN"]
    yl = np.r_[a["nc"], g["nc"]]
    OUT["logit_ap_v2_plus_grid"] = regressions(f"ap_v2 + GRID ap_v1 ({len(yl)})", al, yl,
                                               {"logFr": ["logFr"], "logU": ["logU"], "logFr+logU": ["logFr", "logU"],
                                                "logN+logU": ["logN", "logU"], "logU/N": ["logU_over_N"],
                                                "logN+logU+logh": ["logN", "logU", "logh"],
                                                "logN+logU+logh+ridge+heat": ["logN", "logU", "logh", "ridge", "heat"]}, lam=0.3)

    # 6. SY-12: тот же вопрос на реальном корпусе (m — без нагрева)
    s = np.load(os.path.join(AP, "out", "per_case.npz"), allow_pickle=True)
    ok = (s["n_bv_s"] > 0) & (s["u10_m_s"] > 0) & (s["froude"] > 0) & (s["relief_m"] > 0)
    sf = dict(logFr=np.log(s["froude"][ok]), logU=np.log(s["u_sat_m_s"][ok]), logU10=np.log(s["u10_m_s"][ok]),
              logN=np.log(s["n_bv_s"][ok]), logh=np.log(s["relief_m"][ok]))
    sf["logU_over_N"] = sf["logU"] - sf["logN"]
    ys = (s["status_m"][ok] != 0).astype(float)
    OUT["sy12_n"] = int(ok.sum())
    OUT["logit_sy12_m"] = regressions(f"SY-12 hgw24, решение m ({int(ok.sum())})", sf, ys,
                                      {"logFr": ["logFr"], "logU10": ["logU10"], "logFr+logU10": ["logFr", "logU10"],
                                       "logU/N": ["logU_over_N"], "logN+logU": ["logN", "logU"],
                                       "logN+logU+logh": ["logN", "logU", "logh"]}, lam=0.01, reps=3)
    # SY-12: доля несх. в сетке (U10, U_sat/N) — видно ли «U/N» при фиксированном U10
    rows = []; sy = {}
    un = s["u_sat_m_s"][ok] / s["n_bv_s"][ok]; u10 = s["u10_m_s"][ok]
    for ulo, uhi in ((1.0, 2.0), (2.0, 3.0), (3.0, 5.0)):
        for lo, hi in ((0, 300), (300, 500), (500, 800), (800, 1500), (1500, 1e9)):
            m = (u10 >= ulo) & (u10 < uhi) & (un >= lo) & (un < hi)
            if m.sum() >= 15:
                sy[f"u10_{ulo:g}-{uhi:g}_UN_{lo:g}-{hi:g}"] = dict(n=int(m.sum()), nc_frac=float(ys[m].mean()))
                rows.append([f"{ulo:g}–{uhi:g}", f"{lo:g}–{hi:g}", int(m.sum()), f"{ys[m].mean():.2f}"])
    OUT["sy12_nc_by_u10_and_U_over_N"] = sy
    tab("SY-12 (m): доля несходимости при фиксированном U10 по U_sat/N (м)", ["U10, м/с", "U_sat/N, м", "n", "доля несх."], rows)

    # 7. параметры порядка против Fr при фиксированном ветре; сигмоиды по осям
    sig_res = {}; rows = []
    for name, key, shapes in (("обход (поворот > 45°, 25 м)", "f_turn25", ("ridge",)),
                              ("обратное течение (25 м)", "f_rev25", ("ridge",))):
        for sh in shapes:
            for u in (3.0, 6.0):
                for v in ("both", "n_axis", "h_axis"):
                    m = (a["shape"] == sh) & (a["u_sat"] == u) & ((a["variant"] == v) if v != "both" else True)
                    if m.sum() < 8:
                        continue
                    f = fit_sigmoid(a["fr"][m], a[key][m])
                    sig_res[f"{key}_{sh}_u{u:g}_{v}"] = f
                    if f:
                        rows.append([name, sh, f"{u:g}", v, f["n"], f"{f['x_c']:.2f} [{f['x_c_ci'][0]:.2f}; {f['x_c_ci'][1]:.2f}]",
                                     f"{f['w10_90_dec']:.2f} [{f['w10_90_ci'][0]:.2f}; {f['w10_90_ci'][1]:.2f}]",
                                     f"{f['y0']:.3f}", f"{f['y0'] + f['dy']:.3f}"])
    OUT["order_sigmoids"] = sig_res
    # средние параметры порядка по корзинам Fr: хребет, U_sat, ось (обход, обратное течение — все; σ_w/U — только сошедшиеся)
    rows = []; ob = {}
    for u in (3.0, 6.0):
        for v in ("n_axis", "h_axis"):
            for lo, hi in zip(frbins()[:-1], frbins()[1:]):
                m = (a["shape"] == "ridge") & (a["u_sat"] == u) & (a["variant"] == v) & (a["fr"] >= lo) & (a["fr"] < hi)
                if not m.any():
                    continue
                mc = m & (a["status"] == 0)
                mh = (a["shape"] == "hill") & (a["u_sat"] == u) & (a["variant"] == v) & (a["fr"] >= lo) & (a["fr"] < hi) & (a["status"] == 0)
                rec = dict(n=int(m.sum()), turn25=float(a["f_turn25"][m].mean()), rev25=float(a["f_rev25"][m].mean()),
                           stag25=float(a["f_stag25"][m].mean()),
                           wstd600_rel_ok=float(a["wstd600_rel"][mc].mean()) if mc.any() else None,
                           wstd600_rel_ok_hill=float(a["wstd600_rel"][mh].mean()) if mh.any() else None)
                ob[f"ridge_u{u:g}_{v}_fr{lo:g}-{hi:g}"] = rec
                rows.append([f"{u:g}", v, f"{lo:g}–{hi:g}", rec["n"], f"{rec['turn25']:.3f}", f"{rec['rev25']:.3f}", f"{rec['stag25']:.3f}",
                             f3(rec["wstd600_rel_ok"]), f3(rec["wstd600_rel_ok_hill"])])
    OUT["order_by_fr_ridge"] = ob
    tab("Параметры порядка по Fr (хребет; σ_w/U_sat — только сошедшиеся, последняя колонка — холм)",
        ["U_sat", "ось", "Fr", "n", "обход", "обр. течение", "застой", "σ_w600/U_sat", "σ_w600/U_sat холм"], rows)
    tab("Параметры порядка против Fr: сигмоида y₀ + Δy·σ((lg Fr − lg Fr_c)/w), 90 % интервал бутстрепа",
        ["параметр", "форма", "U_sat", "ось", "n", "Fr_c", "ширина 10–90 %, дек.", "y(Fr→0)", "y(Fr→∞)"], rows)
    # сигмоида несходимости по Fr (U фикс.) и по N (U фикс.)
    nsig = {}
    for u in (3.0, 6.0):
        m = a["u_sat"] == u
        nsig[f"nc_vs_fr_u{u:g}"] = fit_sigmoid(a["fr"][m], a["nc"][m])
        nsig[f"nc_vs_N_u{u:g}"] = fit_sigmoid(a["n_bv"][m], a["nc"][m])
    OUT["nonconv_sigmoids"] = nsig
    # блокирование в сошедшихся: доля сошедшихся с обходом > 0,1 (хребет) — D без несходимости
    m = (a["shape"] == "ridge") & (a["nc"] == 0)
    OUT["ridge_converged_turn25_gt_0.1"] = dict(n=int((m & (a["f_turn25"] > 0.1)).sum()), of=int(m.sum()),
                                                fr_max=float(a["fr"][m & (a["f_turn25"] > 0.1)].max()) if (m & (a["f_turn25"] > 0.1)).any() else None)
    # согласие осей по параметру порядка при одном Fr: разность turn25 (пары n/h при одном U, Fr, форме, H)
    dd = np.array([[a["f_turn25"][i], a["f_turn25"][j], a["f_rev25"][i], a["f_rev25"][j]] for i, j in pv])
    shp = np.array([a["shape"][i] for i, _ in pv])
    OUT["axes_order_agreement"] = {}
    for sh in ("ridge", "hill"):
        q = dd[shp == sh]
        OUT["axes_order_agreement"][sh] = dict(
            n_pairs=int(len(q)), turn25_mean_n_axis=float(q[:, 0].mean()), turn25_mean_h_axis=float(q[:, 1].mean()),
            turn25_mean_abs_diff=float(np.abs(q[:, 0] - q[:, 1]).mean()),
            rev25_mean_n_axis=float(q[:, 2].mean()), rev25_mean_h_axis=float(q[:, 3].mean()),
            rev25_mean_abs_diff=float(np.abs(q[:, 2] - q[:, 3]).mean()))
    # регрессия параметра порядка (хребет, turn25): что объясняет — log Fr или порознь log N, log h, log U
    m = a["shape"] == "ridge"
    Y = a["f_turn25"][m]
    reg = {}
    for mname, keys in {"logFr": ["logFr"], "logN+logh+logU": ["logN", "logh", "logU"],
                        "logFr+logU": ["logFr", "logU"], "logU/N": ["logU_over_N"]}.items():
        X = np.column_stack([np.ones(m.sum())] + [feats[k][m] for k in keys])
        # нелинейность — через сигмоиду по линейной комбинации: аппроксимируем y ~ σ(Xb) МНК
        def fun(Xd, *b):
            return b[-1] / (1 + np.exp(np.clip(Xd @ np.array(b[:-1]), -30, 30)))
        try:
            p, _ = curve_fit(lambda _x, *b: fun(X, *b), np.zeros(len(Y)), Y, p0=[0.0] * X.shape[1] + [0.3], maxfev=40000)
            r2 = 1 - np.sum((Y - fun(X, *p)) ** 2) / np.sum((Y - Y.mean()) ** 2)
            reg[mname] = dict(r2=float(r2), coef=dict(zip(["const"] + keys, map(float, p[:-1]))), amp=float(p[-1]))
        except Exception as e:
            reg[mname] = dict(error=str(e))
    OUT["ridge_turn25_index_regression"] = reg
    tab("Хребет, обход turn25: σ-модель по линейному индексу (R²)", ["индекс", "R²", "коэф."],
        [[k, f3(v.get("r2")), ", ".join(f"{kk} {vv:+.2f}" for kk, vv in v.get("coef", {}).items())] for k, v in reg.items()])

    # 8. метрики слоёв (P6) — если AP-6 влита
    fp = os.path.join(D, "phase", "features_ap_v2.h5")  # P6 v2: таблица в каталоге данных
    OUT["layer_metrics"] = "added" if os.path.exists(fp) else "pending_AP-6"
    if os.path.exists(fp):
        layer_section(fp, a)

    figures(a, g, sig_res)
    verdict()
    with open(os.path.join(HERE, "summary.json"), "w") as f:
        json.dump(OUT, f, ensure_ascii=False, indent=1, default=lambda x: x.tolist() if hasattr(x, "tolist") else str(x))
    with open(os.path.join(HERE, "tables.md"), "w") as f:
        f.write("# AP-7: таблицы (генерируются run.py)\n" + "".join(TAB))
    print(json.dumps({k: OUT[k] for k in ("axes_distinct", "axes_distinct_reason")}, ensure_ascii=False, indent=1))


LAYER_KEYS = {
    "th_n_src": "термики: число источников, шт", "th_w0_mean_ms": "термики: сила ядра w0, м/с",
    "th_ceil_over_zi": "термики: потолок/z_i", "th_src_relief_ratio": "термики: густота источников на рельефе/вне",
    "th_drift_zi_ms": "снос: ветер слоя 0…z_i, м/с",
    "sl_area_km2": "склон: площадь w > 1 м/с, км²", "sl_w_max_ms": "склон: max w 50–300 м, м/с",
    "sl_w_max_over_us": "склон: max w/(U_sat·s)", "sl_ceil_agl_m": "склон: высота w ≥ 1 м/с, м",
    "lee_area25_km2": "подветр.: площадь зоны 25 м, км²", "lee_depth_max_m": "подветр.: глубина зоны, м",
    "lee_desc_max": "подветр.: наклон опускания s_d", "lee_rev_area25_km2": "подветр.: обратное течение 25 м, км²",
    "lee_urev_min_over_us": "подветр.: min u·e/U_sat (25 м)",
}


def _adj_r2(X, y):
    X = np.column_stack([np.ones(len(y)), X])
    b, *_ = np.linalg.lstsq(X, y, rcond=None)
    r = y - X @ b
    ss = np.sum((y - y.mean()) ** 2)
    if ss <= 0:
        return None, b
    r2 = 1 - np.sum(r ** 2) / ss
    n, k = X.shape
    return float(1 - (1 - r2) * (n - 1) / max(n - k, 1)), b


def layer_section(fp, a):
    """Метрики слоёв P6 против Fr при фиксированном ветре: Fr ли это или N и h порознь."""
    with h5py.File(fp, "r") as f:
        t = f["features"][:]
    cid = {int(c): i for i, c in enumerate(t["case_id"])}
    idx = np.array([cid[int(c)] for c in a["case_id"]])
    lfr, lN, lh = np.log(a["fr"]), np.log(a["n_bv"]), np.log(a["h"])
    res = {}; rows = []; prs = {}
    for nm, lab in LAYER_KEYS.items():
        if nm not in t.dtype.names:
            continue
        y_all = t[nm][idx].astype(float)
        per = []
        for u in (3.0, 6.0):
            for sh in ("ridge", "hill"):
                for H in (0.0, 250.0):
                    m = (a["u_sat"] == u) & (a["shape"] == sh) & (a["H"] == H) & np.isfinite(y_all)
                    if m.sum() < 12 or np.std(y_all[m]) == 0:
                        continue
                    y = y_all[m]
                    r_fr, _ = _adj_r2(np.column_stack([lfr[m], lfr[m] ** 2]), y)
                    r_nh, _ = _adj_r2(np.column_stack([lN[m], lh[m], lN[m] ** 2, lh[m] ** 2, lN[m] * lh[m]]), y)
                    _, b = _adj_r2(np.column_stack([lN[m], lh[m]]), y)
                    # пары n/h при одном Fr: |Δ| в долях СКО метрики в группе (все и только обе сошедшиеся)
                    ia = np.where(m & (a["variant"] == "n_axis"))[0]; ib = np.where(m & (a["variant"] == "h_axis"))[0]
                    d_all, d_ok = [], []
                    for i in ia:
                        for j in ib:
                            if abs(lfr[i] - lfr[j]) < 0.03:
                                d = abs(y_all[i] - y_all[j]) / np.std(y)
                                d_all.append(d)
                                if a["status"][i] == 0 and a["status"][j] == 0:
                                    d_ok.append(d)
                    per.append(dict(group=f"u{u:g}_{sh}_H{H:g}", n=int(m.sum()), adj_r2_fr=r_fr, adj_r2_N_h=r_nh,
                                    coef_ratio_h_over_N=float(b[2] / b[1]) if abs(b[1]) > 1e-12 else None,
                                    pair_absdiff_over_std=float(np.mean(d_all)) if d_all else None,
                                    pair_absdiff_over_std_ok=float(np.mean(d_ok)) if d_ok else None, n_pairs_ok=len(d_ok)))
        if not per:
            continue
        med = lambda k: float(np.nanmedian([p[k] for p in per if p[k] is not None])) if any(p[k] is not None for p in per) else None
        res[nm] = dict(label=lab, groups=per, median_adj_r2_fr=med("adj_r2_fr"), median_adj_r2_N_h=med("adj_r2_N_h"),
                       median_coef_ratio_h_over_N=med("coef_ratio_h_over_N"),
                       median_pair_absdiff_over_std=med("pair_absdiff_over_std"),
                       median_pair_absdiff_over_std_ok=med("pair_absdiff_over_std_ok"))
        r = res[nm]
        rows.append([nm, lab, len(per), f3(r["median_adj_r2_fr"]), f3(r["median_adj_r2_N_h"]), f3(r["median_coef_ratio_h_over_N"]),
                     f3(r["median_pair_absdiff_over_std"]), f3(r["median_pair_absdiff_over_std_ok"])])
    OUT["layer_metrics_axes"] = res
    tab("Метрики слоёв (P6) при фиксированном U_sat, форме и H: Fr или N и h порознь (медианы по группам по 37 случаев; "
        "R² — скорректированный, квадратичная модель; отношение коэф. lg h/lg N — 1, если только через Fr; "
        "|Δ| пар n/h при одном Fr в долях СКО метрики — все пары / обе сошлись)",
        ["метрика", "что", "групп", "R² по lg Fr", "R² по lg N, lg h", "lg h/lg N", "|Δ|/СКО пар", "|Δ|/СКО пар (сошл.)"], rows)
    # метрики по корзинам Fr (U_sat, ось): хребет; термики — H = 250, остальное — H = 0
    rows = []; bins = {}
    show = ["th_n_src", "th_w0_mean_ms", "th_ceil_over_zi", "sl_w_max_ms", "sl_area_km2", "lee_area25_km2", "lee_desc_max", "lee_urev_min_over_us"]
    for u in (3.0, 6.0):
        for v in ("n_axis", "h_axis"):
            for lo, hi in zip(frbins()[:-1], frbins()[1:]):
                rec = {}
                for nm in show:
                    H = 250.0 if nm.startswith("th_") else 0.0
                    m = (a["shape"] == "ridge") & (a["u_sat"] == u) & (a["variant"] == v) & (a["H"] == H) & (a["fr"] >= lo) & (a["fr"] < hi)
                    y = t[nm][idx][m].astype(float)
                    y = y[np.isfinite(y)]
                    rec[nm] = float(np.mean(y)) if len(y) else None
                if all(x is None for x in rec.values()):
                    continue
                bins[f"ridge_u{u:g}_{v}_fr{lo:g}-{hi:g}"] = rec
                rows.append([f"{u:g}", v, f"{lo:g}–{hi:g}"] + [f3(rec[k]) for k in show])
    OUT["layer_metrics_by_fr_ridge"] = bins
    tab("Метрики слоёв по Fr, хребет (th_* — H = 250, остальные — H = 0; средние)", ["U_sat", "ось", "Fr"] + show, rows)


def figures(a, g, sig_res):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    col = {3.0: "#2a6fb0", 6.0: "#d0632a"}
    mk = {"n_axis": "o", "h_axis": "s"}
    # 1. несходимость: разброс поздних итераций против Fr
    fig, ax = plt.subplots(1, 2, figsize=(11, 4.2))
    for u in (3.0, 6.0):
        for v in ("n_axis", "h_axis"):
            m = (a["u_sat"] == u) & (a["variant"] == v)
            sp = np.where(a["status"][m] == 0, 3e-3, np.maximum(a["late_spread60_p90"][m], 3e-3))
            ax[0].scatter(a["fr"][m], sp, s=18, c=col[u], marker=mk[v], alpha=0.7, label=f"U_sat {u:g}, {v}")
            ax[1].scatter(a["n_bv"][m], sp, s=18, c=col[u], marker=mk[v], alpha=0.7)
    for x in ax:
        x.set_xscale("log"); x.set_yscale("log"); x.axhline(NEAR, color="0.5", ls="--", lw=0.8)
        x.set_ylabel("разброс поздних итераций p90, м/с (сошлось → 0,003)")
    ax[0].set_xlabel("Fr = U_sat/(N·h)"); ax[1].set_xlabel("N над z_i, 1/с"); ax[0].legend(fontsize=7)
    ax[0].set_title("несходимость против Fr"); ax[1].set_title("против N (тот же набор)")
    fig.tight_layout(); fig.savefig(os.path.join(HERE, "fig_nonconv_fr_vs_n.png"), dpi=120); plt.close(fig)
    # 2. плоскость (N, U_sat) + линии Fr; GRID
    fig, ax = plt.subplots(figsize=(6.5, 4.8))
    for u in (3.0, 6.0):
        m = a["u_sat"] == u
        jit = u * (1 + 0.04 * (a["h"][m] / 1500 - 0.5))
        ax.scatter(a["n_bv"][m], jit, c=np.where(a["nc"][m] > 0, "#c0392b", "#27ae60"), s=14, marker="o", alpha=0.6)
    gs = g["u_sat"]
    ax.scatter(g["n_bv"] * (1 + 0.03 * (g["shape"] == "hill")), gs, c=np.where(g["nc"] > 0, "#c0392b", "#27ae60"), s=10, marker="x", alpha=0.6)
    ax.set_xscale("log"); ax.set_yscale("log"); ax.set_xlabel("N, 1/с"); ax.set_ylabel("U_sat, м/с (точки ap_v2 слегка раздвинуты по h)")
    ax.set_title("красный — несходимость; o — ap_v2, x — GRID ap_v1 (N = 0,01)")
    fig.tight_layout(); fig.savefig(os.path.join(HERE, "fig_plane_n_u.png"), dpi=120); plt.close(fig)
    # 3. параметры порядка против Fr
    fig, ax = plt.subplots(1, 3, figsize=(14, 4.2))
    for i, (key, lab) in enumerate((("f_turn25", "обход: доля поворота > 45° (25 м)"), ("f_rev25", "обратное течение (25 м)"),
                                    ("wstd600_rel", "σ_w(600 м)/U_sat"))):
        for u in (3.0, 6.0):
            for v in ("n_axis", "h_axis"):
                m = (a["u_sat"] == u) & (a["variant"] == v) & (a["shape"] == "ridge")
                ax[i].scatter(a["fr"][m], a[key][m], s=16, c=col[u], marker=mk[v], alpha=0.6, label=f"хребет U {u:g} {v}")
                m2 = (a["u_sat"] == u) & (a["variant"] == v) & (a["shape"] == "hill")
                ax[i].scatter(a["fr"][m2], a[key][m2], s=16, facecolors="none", edgecolors=col[u], marker=mk[v], alpha=0.6)
        ax[i].set_xscale("log"); ax[i].set_xlabel("Fr"); ax[i].set_title(lab, fontsize=9)
    ax[0].legend(fontsize=7)
    fig.tight_layout(); fig.savefig(os.path.join(HERE, "fig_order_fr.png"), dpi=120); plt.close(fig)
    # 4. итерации сошедшихся (критическое замедление) против Fr и против N
    fig, ax = plt.subplots(1, 2, figsize=(11, 4))
    for u in (3.0, 6.0):
        for v in ("n_axis", "h_axis"):
            m = (a["u_sat"] == u) & (a["variant"] == v) & (a["status"] == 0)
            ax[0].scatter(a["fr"][m], a["iters"][m], s=16, c=col[u], marker=mk[v], alpha=0.7, label=f"U {u:g} {v}")
            ax[1].scatter(a["n_bv"][m], a["iters"][m], s=16, c=col[u], marker=mk[v], alpha=0.7)
    for x in ax:
        x.set_xscale("log"); x.set_yscale("log"); x.set_ylabel("итераций (сошедшиеся)")
    ax[0].set_xlabel("Fr"); ax[1].set_xlabel("N, 1/с"); ax[0].legend(fontsize=7)
    fig.tight_layout(); fig.savefig(os.path.join(HERE, "fig_slowing.png"), dpi=120); plt.close(fig)


def verdict():
    pv = OUT["pairs_naxis_vs_haxis_same_fr_u"]; pu = OUT["pairs_u3_vs_u6_same_fr"]
    l0 = OUT["logit_ap_v2_H0"]
    OUT["axes_distinct"] = "partly"
    OUT["axes_distinct_reason"] = (
        "Несходимость (H = 0) задаёт не Fr и не ветер по отдельности, а N при данном U: порог N_c = "
        f"{OUT['n_crit_H0_by_u_sat']['3']:.4f} (U_sat 3) и {OUT['n_crit_H0_by_u_sat']['6']:.4f} 1/с (U_sat 6), "
        f"N_c ∝ U_sat^{OUT['n_crit_exponent_vs_u_sat']:.2f}; h почти не влияет (отношение коэффициентов lg h/lg N "
        f"{OUT['H0_raw_coef_ratio_h_over_N']:.2f}, у Fr было бы 1). CV log-loss: lg Fr {l0['logFr']['cv_logloss']:.3f}, "
        f"lg Fr + lg U {l0['logFr+logU']['cv_logloss']:.3f}, lg N + lg U {l0['logN+logU']['cv_logloss']:.3f}. "
        f"При одном Fr и U оси N и h расходятся в {pv['only_a_nc'] + pv['only_b_nc']}/{pv['n_pairs']} пар, два ветра при одном Fr — "
        f"в {pu['only_a_nc'] + pu['only_b_nc']}/{pu['n_pairs']}. Параметры порядка блокирования (обход, обратное течение) следуют Fr "
        "на обеих осях (граница D — по Fr). Итого: Fr (блокирование D) и область несходимости — разные оси, но вторая — "
        "не «слабый ветер» U10, а устойчивость относительно ветра (N/U^0,6…0,7) плюс конвекция при w*/U10 ≳ 0,8."
        + (" Метрики слоёв P6: по Fr идёт только разрешённое обратное течение за хребтом; зона отрыва игры, подъём у склонов "
           "и термики зависят от h (z_i) и N порознь — одного Fr слоям мало." if "layer_metrics_axes" in OUT else ""))


if __name__ == "__main__":
    sys.exit(main())
