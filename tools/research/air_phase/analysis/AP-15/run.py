"""AP-15: три малые пробы плана ap_probe (серия PROBE) — ветвь у уступа, период цикла у порога U/N, λ K-замыкания.

Запуск (CPU, < 1 мин; счёт — probe_build.py run под замком GPU):
  /home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python \
      tools/research/air_phase/analysis/AP-15/run.py [--plan DIR] [--results DIR]

Вход — только чтение: план P2 (`plan.json`), части P3 (`cases`, `fields/f`, `order`, `window/*`), трассы каждой итерации
`<results>/probe/case-<id>.h5` (probe_build.py), для сравнения — таблица признаков ap_v1 (`features_ap_v1.h5`, P6) и
`analysis/AP-10/out/bubble_v2.csv` (пузырь SEPARATION ap_v1 при λ = 40 м). Выход (P7): summary.json, fig_*.png.
"""
from __future__ import annotations

import argparse
import csv
import importlib.util
import json
import math
import sys
from pathlib import Path

import h5py
import numpy as np

HERE = Path(__file__).resolve().parent
AP = HERE.parents[1]
sys.path.insert(0, str(AP))
import bubble as B  # noqa: E402

_spec = importlib.util.spec_from_file_location("ap10", AP / "analysis/AP-10/run.py")
AP10 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(AP10)

DATA = Path.home() / "air_synth_data/phase"
AGL = np.array([25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000], float)
LOW = AGL <= 600                      # слой сравнения ветвей (как AP-8: ≤ 600 м)
BR_THR = 0.1                          # |Δu| > 0,1 U_sat …
BR_FRAC = 0.01                        # … в ≥ 1 % объёма — «ветвь» (AP-8 п. 5)
LATE_FROM = 1000                      # dumax: поздний участок для периода
DTAU_U = 120.0                        # с, псевдошаг Δτ_u решателя (AP-13) — для перевода в псевдовремя
LIT_L = (2.8, 3.5)                    # L/h: Perdigão, 2D-хребет (AP-10)
LIT_ANGLE_RIDGE = 16.0
BR_S = (0.15, 0.3)


def find_results(plan_dir):
    c = sorted(DATA.glob(Path(plan_dir).name + "__*"), key=lambda p: p.stat().st_mtime)
    return c[-1]


def load(plan_dir, rdir):
    P = json.loads((Path(plan_dir) / "plan.json").read_text())
    lines = {l["line_id"]: l for l in P["lines"]}
    rel = {r["relief_id"]: r for r in P["reliefs"]}
    rows = {}
    for p in sorted(Path(rdir).glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            c = h["cases"][:]
            o = h["order"][:]
            wid = list(h["window/case_id"][:]) if "window" in h else []
            for j, r in enumerate(c):
                d = {k: r[k].item() for k in c.dtype.names}
                d.update({f"o_{k}": float(o[j][k]) for k in o.dtype.names})
                L = lines[d["line_id"]]
                d.update(part=str(p), row=j, win=wid.index(d["case_id"]) if d["case_id"] in wid else -1, variant=L["variant"],
                         start=L["start"], direction=L["direction"], lam_m=float(L["numerics"]["lam_m"]), tol=float(L["numerics"]["tol"]),
                         shape=rel[L["relief_id"]]["shape"], slope=float(rel[L["relief_id"]]["slope"]),
                         h_m=float(rel[L["relief_id"]]["h_m"]))
                rows[d["case_id"]] = d
    return P, lines, rows


def fields(r):
    with h5py.File(r["part"], "r") as h:
        return h["fields/f"][r["row"]].astype(np.float32)


# ============================================================================== 1. ветвь у уступа
def chain_of(r):
    return {"COLD": "cold", "WARM_PREV": {"UP": "up", "DOWN": "down"}.get(r["direction"], "?")}[r["start"]]


def ref_ap_v1():
    """f_rev25 / f_stag25 у уступа (h/z_i = 1, H = 0) в ap_v1 при обычном критерии: GRID (холодный), SWEEP up/down."""
    p = DATA / "features_ap_v1.h5"
    if not p.exists():
        return {}
    d = h5py.File(p, "r")["features"][:]
    sel = (d["shape"] == b"STEP_UP") & np.isclose(d["h_over_zi"], 1.0) & (d["heat_flux_wm2"] == 0) & (d["fr"] > 0.8) & (d["fr"] < 1.0)
    out = {}
    for r in d[sel]:
        ch = {1: "cold", 2: r["variant"].decode()}.get(int(r["series"]))
        if ch is None:
            continue
        out[f"s{float(r['slope']):.2f}_fr{float(r['fr']):.2f}_{ch}"] = dict(f_rev25=round(float(r["f_rev25"]), 4),
                                                                         f_stag25=round(float(r["f_stag25"]), 4),
                                                                         status=int(r["status"]), iters=int(r["iters"]))
    return out


def ap_v1_pairs():
    """Те же пары (cold/up/down) при обычном критерии tol 2e-5: ap_v1 GRID (холодный) и SWEEP up/down, уступ, H = 0, h/z_i = 1."""
    pdir, rdir = DATA / "ap_v1", DATA / "ap_v1__s1-74644c4"
    if not (pdir / "plan.json").exists() or not rdir.exists():
        return []
    P = json.loads((pdir / "plan.json").read_text())
    rel = {r["relief_id"]: r for r in P["reliefs"]}
    want = {}
    for l in P["lines"]:
        r = rel[l["relief_id"]]
        if r["shape"] != "STEP_UP" or round(float(r["slope"]), 2) not in BR_S or l["heat_flux_wm2"] != 0 or l["h_over_zi"] != 1.0:
            continue
        ch = {"GRID": "cold"}.get(l["series"], l.get("variant") if l["series"] == "SWEEP" else None)
        if ch not in ("cold", "up", "down"):
            continue
        for k, fr in enumerate(l["fr"]):
            if any(abs(fr - x) < 1e-6 for x in (0.85, 0.9, 0.95)):
                want[int(l["first_case_id"]) + k] = (round(float(r["slope"]), 2), round(fr, 2), ch)
    got = {}
    for p in sorted(rdir.glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            c = h["cases"][:]
            for j in np.nonzero(np.isin(c["case_id"], list(want)))[0]:
                got[want[int(c["case_id"][j])]] = (h["fields/f"][j].astype(np.float32), int(c["status"][j]), float(c["u_sat"][j]),
                                                   float(h["order"][j]["f_rev25"]))
    out = []
    for s in BR_S:
        for fr in (0.85, 0.9, 0.95):
            for a, b in (("cold", "up"), ("cold", "down"), ("up", "down")):
                if (s, fr, a) not in got or (s, fr, b) not in got:
                    continue
                A, Bf = got[(s, fr, a)], got[(s, fr, b)]
                du = np.abs(A[0][:3, LOW] - Bf[0][:3, LOW]).max(axis=0)
                U = A[2]
                out.append(dict(s=s, fr=fr, pair=f"{a}-{b}", both_converged=A[1] == 0 and Bf[1] == 0, max_over_U=float(du.max() / U),
                                p99_over_U=float(np.quantile(du, 0.99) / U), frac_gt=float(np.mean(du > BR_THR * U)),
                                d_f_rev25=abs(A[3] - Bf[3])))
    return out


def branch_part(rows, tight_rows=None):
    br = [r for r in list(rows.values()) + list((tight_rows or {}).values()) if r["variant"] == "branch"]
    groups = {}
    for r in br:
        if any(abs(r["fr"] - x) < 1e-4 for x in (0.85, 0.9, 0.95)):
            groups.setdefault((round(r["slope"], 2), round(r["fr"], 2), r["tol"]), {})[chain_of(r)] = r
    out, pairs = [], []
    for (s, fr, tol), g in sorted(groups.items(), key=lambda t: (t[0][0], t[0][1])):
        F = {k: fields(v) for k, v in g.items()}
        U = float(next(iter(g.values()))["u_sat"])
        ent = dict(s=s, fr=fr, tol=tol, u_sat=U, states={k: dict(status=v["status"], iters=v["iters"], resid=v["resid_final"],
                                                         f_rev25=v.get("o_f_rev25"), f_stag25=v.get("o_f_stag25"),
                                                         f_turn25=v.get("o_f_turn25")) for k, v in g.items()})
        for a, b in (("cold", "up"), ("cold", "down"), ("up", "down")):
            if a not in F or b not in F:
                continue
            d = np.abs(F[a][:3, LOW] - F[b][:3, LOW])
            du = d.max(axis=0)                       # по компонентам u, v, w
            both_ok = g[a]["status"] == 0 and g[b]["status"] == 0
            pr = dict(s=s, fr=fr, tol=tol, pair=f"{a}-{b}", both_converged=bool(both_ok), max_over_U=float(du.max() / U),
                      p99_over_U=float(np.quantile(du, 0.99) / U), frac_gt=float(np.mean(du > BR_THR * U)),
                      d_f_rev25=abs(float(g[a].get("o_f_rev25", np.nan)) - float(g[b].get("o_f_rev25", np.nan))))
            pr["branch"] = bool(pr["frac_gt"] >= BR_FRAC)
            pairs.append(pr)
        out.append(ent)
    # ветвь — если расхождение не уходит вместе с допуском: сравнение с теми же парами ap_v1 (tol 2e-5, GRID/SWEEP)
    main = [p for p in pairs if abs(p["tol"] - 2e-6) < 1e-12]
    tight = {(p["s"], p["fr"], p["pair"]): p for p in pairs if abs(p["tol"] - 2e-7) < 1e-13}
    conv_pairs = [p for p in main if p["both_converged"]]
    flagged = [p for p in conv_pairs if p["branch"]]
    old = {(p["s"], p["fr"], p["pair"]): p for p in ap_v1_pairs()}
    scaling = []
    for p in main:
        o = old.get((p["s"], p["fr"], p["pair"]))
        if o is not None:
            scaling.append(dict(s=p["s"], fr=p["fr"], pair=p["pair"], old_both_converged=o["both_converged"],
                                p99_over_U_tol2e5=o["p99_over_U"], p99_over_U_tol2e6=p["p99_over_U"],
                                p99_ratio=o["p99_over_U"] / max(p["p99_over_U"], 1e-9),
                                frac_gt_tol2e5=o["frac_gt"], frac_gt_tol2e6=p["frac_gt"],
                                d_f_rev25_tol2e5=o["d_f_rev25"], d_f_rev25_tol2e6=p["d_f_rev25"]))
    sc = {(x["s"], x["fr"], x["pair"]): x for x in scaling}
    if not conv_pairs or len(conv_pairs) < 0.75 * len(main):
        verdict = "unclear"
    elif not flagged:
        verdict = "no"
    elif tight and all((f["s"], f["fr"], f["pair"]) in tight for f in flagged):
        tt = [(f, tight[(f["s"], f["fr"], f["pair"])]) for f in flagged]
        if all(t["both_converged"] and not t["branch"] and f["p99_over_U"] / max(t["p99_over_U"], 1e-9) >= 3 for f, t in tt):
            verdict = "no"
        elif all(t["both_converged"] and t["branch"] and f["p99_over_U"] / max(t["p99_over_U"], 1e-9) < 1.5 for f, t in tt):
            verdict = "yes"
        else:
            verdict = "unclear"
    elif all((f["s"], f["fr"], f["pair"]) in sc and sc[(f["s"], f["fr"], f["pair"])]["p99_ratio"] >= 3 for f in flagged):
        verdict = "no"            # расхождение уходит вместе с допуском: ошибка ~ε/(1−ρ), а не вторая неподвижная точка
    elif all((f["s"], f["fr"], f["pair"]) in sc and sc[(f["s"], f["fr"], f["pair"])]["p99_ratio"] < 1.5 for f in flagged):
        verdict = "yes"
    else:
        verdict = "unclear"
    n_br_conv = len(flagged)
    return dict(verdict=verdict, groups=out, pairs=pairs, n_pairs=len(main), n_pairs_converged=len(conv_pairs),
                tol_scaling=scaling, tight_pairs=list(tight.values()), tight_available=bool(tight),
                n_branch_converged=int(n_br_conv), n_branch_any=int(sum(p["branch"] for p in main)),
                criterion=f"|Δ(u,v,w)| > {BR_THR} U_sat в ≥ {BR_FRAC:.0%} клеток 13 уровней ≤ 600 м, оба сошлись (tol 2e-6)",
                ref_ap_v1=ref_ap_v1())


# ============================================================================== 2. период цикла у порога
def spectral_period(x, pmin=3.0, pmax=400.0):
    """Период по пику спектра (Ханн, линейный тренд снят, параболическое уточнение); → (период, доля мощности пика)."""
    x = np.asarray(x, float)
    x = x - np.polyval(np.polyfit(np.arange(x.size), x, 1), np.arange(x.size))
    if not np.any(x):
        return float("nan"), 0.0
    X = np.abs(np.fft.rfft(x * np.hanning(x.size))) ** 2
    f = np.fft.rfftfreq(x.size)
    m = (f >= 1 / pmax) & (f <= 1 / pmin)
    if not m.any():
        return float("nan"), 0.0
    idx = np.nonzero(m)[0]
    k = idx[np.argmax(X[idx])]
    fk = f[k]
    if 0 < k < len(X) - 1:
        a, b, c = np.log(X[k - 1] + 1e-30), np.log(X[k] + 1e-30), np.log(X[k + 1] + 1e-30)
        den = a - 2 * b + c
        if den != 0:
            fk = f[k] + 0.5 * (a - c) / den * (f[1] - f[0])
    band = (f > fk * 0.9) & (f < fk * 1.1)
    return float(1 / fk), float(X[band].sum() / X[m].sum())


def acf_period(x, pmax=400):
    x = np.asarray(x, float) - np.mean(x)
    n = x.size
    a = np.correlate(x, x, "full")[n - 1:n - 1 + pmax] / (np.dot(x, x) + 1e-30)
    neg = np.nonzero(a < 0)[0]
    if neg.size == 0:
        return float("nan"), float("nan")
    k = neg[0] + int(np.argmax(a[neg[0]:]))
    return float(k), float(a[k])


def dumax_part(rows, rdir, P):
    sel = {s["line_id"]: s for s in P.get("probe_selection", []) if s["variant"] == "dumax"}
    out = {}
    for r in sorted((r for r in rows.values() if r["variant"] == "dumax"), key=lambda r: r["case_id"]):
        p = Path(rdir) / "probe" / f"case-{r['case_id']:05d}.h5"
        with h5py.File(p, "r") as h:
            it, du1, res, cols = h["iter"][:], h["du1"][:], h["resid"][:], h["cols"][:]
            hc, zb, dz, xs = h["hc_cols_m"][:], float(h.attrs["z_bot_m"]), float(h.attrs["dz_m"]), h["cols_x_m"][:]
        key = f"U{r['u_sat']:.0f}_N{r['n_bv']:.4f}"
        e = dict(case_id=r["case_id"], u_sat=r["u_sat"], n_bv=r["n_bv"], fr=r["fr"], status=r["status"], iters=r["iters"],
                 n_records=int(it.size), iter_step=int(np.median(np.diff(it))) if it.size > 1 else 0)
        late = it >= LATE_FROM
        if r["status"] == 0 or late.sum() < 200:
            e["period_iters"] = None
            out[key] = e
            continue
        z = zb + (np.arange(cols.shape[-1]) - 0.5) * dz            # центры клеток с ореолом (k = 0 — под низом)
        cu = cols[late][:, :, 0, :]                                 # (T, col, k) u
        sd = cu.std(axis=0)                                         # (col, k)
        agl = z[None, :] - hc[:, None]
        sd = np.where((agl > 0) & (np.arange(cols.shape[-1])[None] <= cols.shape[-1] - 2), sd, 0.0)
        per_col = []
        for c in range(cu.shape[1]):
            k = int(np.argmax(sd[c]))
            per, pw = spectral_period(cu[:, c, k])
            pa, aa = acf_period(cu[:, c, k])
            # высота, где колебание сосредоточено: max σ_u и полуширина профиля σ_u(z) по высоте над землёй
            prof = sd[c]
            above = prof > 0.5 * prof.max()
            per_col.append(dict(x_m=float(xs[c]), k_max=k, z_agl_max_m=float(agl[c, k]), sigma_u_max=float(prof.max()),
                                z_agl_half_lo_m=float(agl[c][above].min()), z_agl_half_hi_m=float(agl[c][above].max()),
                                period_spec=per, peak_power_frac=pw, period_acf=pa, acf_peak=aa))
        pd, pwd = spectral_period(np.log(du1[late] + 1e-12))
        pr, pwr = spectral_period(np.log(res[late] + 1e-30))
        strong = [c for c in per_col if c["sigma_u_max"] >= 0.3 * max(cc["sigma_u_max"] for cc in per_col)]
        e.update(columns=per_col, period_du1=pd, period_du1_power=pwd, period_resid=pr, period_resid_power=pwr,
                 period_iters=float(np.median([c["period_spec"] for c in strong])),
                 period_spread=[float(min(c["period_spec"] for c in strong)), float(max(c["period_spec"] for c in strong))],
                 du1_late_median=float(np.median(du1[late])), du1_ratio_last_first_third=float(
                     np.median(du1[late][-du1[late].size // 3:]) / np.median(du1[late][: du1[late].size // 3])),
                 x_sigma_max_m=float(max(per_col, key=lambda c: c["sigma_u_max"])["x_m"]))
        e["period_pseudotime_s"] = e["period_iters"] * DTAU_U
        lam_z = 2 * math.pi * r["u_sat"] / r["n_bv"]
        e.update(period_over_fr=e["period_iters"] / r["fr"], lambda_z_m=lam_z, dz_m=dz,
                 lambda_z_per_iter_over_dz=lam_z / e["period_iters"] / dz)
        # доля σ_u² по слоям над землёй (верх области — 3000 м над max рельефа, губка — верхние 1000 м)
        bins = ((0, 300), (300, 1000), (1000, 2000), (2000, 2500), (2500, 1e9))
        var = cu.var(axis=0)
        okm = (agl > 0) & (np.arange(cols.shape[-1])[None] <= cols.shape[-1] - 2)
        tot = float(np.sum(var[okm]))
        e["var_frac_by_agl"] = {f"{lo:.0f}-{hi:.0f}": float(np.sum(var[okm & (agl >= lo) & (agl < hi)]) / tot) for lo, hi in bins}
        e["sponge_from_agl_m"] = [float(zb + dz * (cols.shape[-1] - 2) - 1000.0 - x) for x in hc]
        out[key] = e
    return out


# ============================================================================== 3. λ K-замыкания
def lam_part(rows, P):
    ctx = P["context"]
    inflow = (ctx["alpha"], ctx["max_profile"])
    res = []
    for r in sorted((r for r in rows.values() if r["variant"] == "lam"), key=lambda r: r["case_id"]):
        e = AP10.wind_e(r["wdir_from_deg"])
        with h5py.File(r["part"], "r") as hf:
            q = r["win"]
            ny, nx = hf["window/shape"][q][-2:]
            f = hf["window/fields"][q][:, :, :ny, :nx].astype(np.float32)
            g = hf["window/hc"][q][:ny, :nx].astype(float)
            x0, y0 = float(hf["window/x0_m"][q]), float(hf["window/y0_m"][q])
            c = (float(hf["window/brink_x_m"][q]), float(hf["window/brink_y_m"][q]))
            wst, wit = int(hf["window/status"][q]), int(hf["window/iters"][q])
        h, U, N = r["h_m"], r["u_sat"], r["n_bv"]
        b = B.bubble(f, AGL, x0, y0, 100.0, g, e, h, U, N, center=c, edge=0, inflow=inflow)
        d = dict(case_id=r["case_id"], shape=r["shape"], s=round(r["slope"], 2), lam_m=r["lam_m"], status=r["status"],
                 iters=r["iters"], win_status=wst, win_iters=wit)
        d.update({k: float(b[k]) for k in b.dtype.names})
        s, zs, al, w = AP10.sec_data(f, AGL, x0, y0, 100.0, g, e, c)
        d.update(AP10.bubble_diag(s, zs, al, w, AGL, h, U))
        d["sec"] = dict(s=s, zs=zs, al=al)
        res.append(d)
    # эталон ap_v1 (λ = 40) — пересчёт AP-10
    ref = {}
    p = AP / "analysis/AP-10/out/bubble_v2.csv"
    if p.exists():
        for row in csv.DictReader(open(p)):
            if row["dx_m"] in ("100", "100.0") and row["variant"] == "slope" and float(row["fr"]) == 3.0:
                ref[(row["shape"], round(float(row["slope"]), 2))] = dict(L_over_h=float(row["L_over_h"]),
                                                                           shadow_angle_deg=float(row["shadow_angle_deg"]),
                                                                           urev_over_U=float(row["urev_over_U"]),
                                                                           shear_S_pope=float(row.get("shear_S_pope") or "nan"))
    return res, ref


def lam_verdict(res):
    by = {}
    for d in res:
        by.setdefault((d["shape"], d["s"]), {})[d["lam_m"]] = d
    rows = []
    for (sh, s), g in sorted(by.items()):
        if 40.0 not in g:
            continue
        a = g[40.0]
        for lam, d in sorted(g.items()):
            rows.append(dict(shape=sh, s=s, lam_m=lam, L_over_h=d["L_over_h"], L_ratio=d["L_over_h"] / a["L_over_h"] if a["L_over_h"] else float("nan"),
                             shadow_angle_deg=d["shadow_angle_deg"], urev_over_U=d["urev_over_U"],
                             H_over_h=d["H_over_h"], S=d.get("shear_S_pope", float("nan")), sep_over_h=d.get("sep_over_h", float("nan")),
                             has_reverse=int(d["has_reverse"]), status=d["status"], win_status=d["win_status"]))
    ridge160 = [r for r in rows if r["shape"] == "RIDGE" and r["lam_m"] == 160.0]
    ridge40 = [r for r in rows if r["shape"] == "RIDGE" and r["lam_m"] == 40.0]
    if not ridge160:
        return "partly", rows
    Lr = np.mean([r["L_ratio"] for r in ridge160])
    L160 = [r["L_over_h"] for r in ridge160]
    ang160 = [r["shadow_angle_deg"] for r in ridge160]
    if all(x <= 4.0 for x in L160) and all(a >= 14.0 for a in ang160):
        v = "yes"
    elif Lr <= 0.85 or (np.mean(ang160) - np.mean([r["shadow_angle_deg"] for r in ridge40]) >= 2.0):
        v = "partly"
    else:
        v = "no"
    return v, rows


# ============================================================================== рисунки
def figs(br, dm, lam_res, lam_rows, rdir):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    col = {"cold": "#555555", "up": "#c0392b", "down": "#2e86c1"}
    # 1. ветвь: f_rev25 против Fr
    ss = sorted({g["s"] for g in br["groups"]})
    fig, axs = plt.subplots(1, len(ss), figsize=(5 * len(ss), 3.6), squeeze=False)
    for ax, s in zip(axs[0], ss):
        for ch in ("cold", "up", "down"):
            pts = [(g["fr"], g["states"][ch]["f_rev25"], g["states"][ch]["status"]) for g in br["groups"] if g["s"] == s and ch in g["states"] and abs(g["tol"] - 2e-6) < 1e-12]
            for g in br["groups"]:
                if g["s"] == s and ch in g["states"] and abs(g["tol"] - 2e-7) < 1e-13:
                    ax.plot(g["fr"], g["states"][ch]["f_rev25"], "*", color=col[ch], ms=12, label=f"{ch}, tol 2e-7")
            if pts:
                x, y, st = zip(*sorted(pts))
                ax.plot(x, y, "-o", color=col[ch], label=f"{ch}, tol 2e-6")
                for xi, yi, si in zip(x, y, st):
                    if si != 0:
                        ax.plot(xi, yi, "x", color="k", ms=10)
            ref = sorted((float(k.split("_fr")[1].split("_")[0]), v["f_rev25"]) for k, v in br["ref_ap_v1"].items()
                         if k.startswith(f"s{s:.2f}_") and k.endswith("_" + ch))
            if ref:
                x, y = zip(*ref)
                ax.plot(x, y, "--", color=col[ch], alpha=0.5, label=f"{ch}, ap_v1 tol 2e-5")
        ax.set_title(f"уступ s = {s}, h/z_i = 1, H = 0")
        ax.set_xlabel("Fr"); ax.set_ylabel("f_rev25 (доля обратного течения, 25 м)")
    axs[0][0].legend(fontsize=7)
    fig.tight_layout(); fig.savefig(HERE / "fig_branch.png", dpi=110); plt.close(fig)

    # 2. du1 и u колонны по итерациям
    keys = [k for k, e in dm.items() if e.get("period_iters")]
    if keys:
        fig, axs = plt.subplots(len(keys), 2, figsize=(11, 2.6 * len(keys)), squeeze=False)
        for row, k in zip(axs, keys):
            e = dm[k]
            with h5py.File(Path(rdir) / "probe" / f"case-{e['case_id']:05d}.h5", "r") as h:
                it, du1, cols = h["iter"][:], h["du1"][:], h["cols"][:]
            row[0].semilogy(it, du1, lw=0.4, color="#333")
            row[0].set_title(f"{k}: du1 = max|x_t − x_(t−1)|, м/с"); row[0].set_xlabel("итерация")
            c = max(range(len(e["columns"])), key=lambda i: e["columns"][i]["sigma_u_max"])
            kk = e["columns"][c]["k_max"]
            m = (it >= 2500) & (it < 2700)
            row[1].plot(it[m], cols[m, c, 0, kk], lw=0.8, marker=".", ms=2)
            row[1].set_title(f"u в колонне x = {e['columns'][c]['x_m']:.0f} м, {e['columns'][c]['z_agl_max_m']:.0f} м над землёй; "
                             f"период {e['period_iters']:.1f} ит.", fontsize=8)
            row[1].set_xlabel("итерация")
        fig.tight_layout(); fig.savefig(HERE / "fig_dumax_traces.png", dpi=110); plt.close(fig)

        # 3. вертикальная структура σ_u(z) по колоннам
        fig, axs = plt.subplots(1, len(keys), figsize=(4.2 * len(keys), 4), squeeze=False)
        for ax, k in zip(axs[0], keys):
            e = dm[k]
            with h5py.File(Path(rdir) / "probe" / f"case-{e['case_id']:05d}.h5", "r") as h:
                it, cols, hc = h["iter"][:], h["cols"][:], h["hc_cols_m"][:]
                zb, dz = float(h.attrs["z_bot_m"]), float(h.attrs["dz_m"])
            z = zb + (np.arange(cols.shape[-1]) - 0.5) * dz
            sd = cols[it >= LATE_FROM][:, :, 0, :].std(axis=0)
            for c, cc in enumerate(e["columns"]):
                agl = z - hc[c]
                m = (agl > 0) & (np.arange(z.size) <= z.size - 2)
                ax.plot(sd[c][m], agl[m], label=f"x = {cc['x_m']:.0f} м")
            ax.set_title(f"{k}: σ_u поздних итераций", fontsize=9); ax.set_xlabel("σ_u, м/с"); ax.set_ylabel("над землёй, м")
        axs[0][0].legend(fontsize=7)
        fig.tight_layout(); fig.savefig(HERE / "fig_dumax_vertical.png", dpi=110); plt.close(fig)

    # 4. λ: L/h, угол тени, S против λ
    fig, axs = plt.subplots(1, 3, figsize=(13, 3.6))
    for (sh, s) in sorted({(r["shape"], r["s"]) for r in lam_rows}):
        rr = sorted((r for r in lam_rows if r["shape"] == sh and r["s"] == s), key=lambda r: r["lam_m"])
        x = [r["lam_m"] for r in rr]
        for ax, kk in zip(axs, ("L_over_h", "shadow_angle_deg", "S")):
            ax.plot(x, [r[kk] for r in rr], "-o", label=f"{sh.lower()} s = {s}")
    axs[0].axhspan(*LIT_L, color="g", alpha=0.15, label="литература 2,8–3,5 h")
    axs[1].axhline(LIT_ANGLE_RIDGE, color="g", ls="--", label="2D-хребет 16°")
    axs[2].axhspan(0.06, 0.11, color="g", alpha=0.15, label="плоский слой смешения")
    for ax, t in zip(axs, ("длина пузыря L/h", "угол тени, °", "рост слоя смешения S")):
        ax.set_xscale("log", base=2); ax.set_xlabel("λ, м"); ax.set_title(t); ax.legend(fontsize=7)
    fig.tight_layout(); fig.savefig(HERE / "fig_lam_bubble.png", dpi=110); plt.close(fig)

    # 5. сечения u·e хребта s = 0,5 при λ 40 и 160
    sec = [d for d in lam_res if d["shape"] == "RIDGE" and d["s"] == 0.5 and d["lam_m"] in (40.0, 160.0)]
    if sec:
        fig, axs = plt.subplots(len(sec), 1, figsize=(10, 2.8 * len(sec)), squeeze=False)
        for ax, d in zip(axs[:, 0], sorted(sec, key=lambda d: d["lam_m"])):
            s_, zs, al = d["sec"]["s"], d["sec"]["zs"], d["sec"]["al"]
            S2, Z2 = np.meshgrid(s_, AGL)
            pc = ax.pcolormesh(S2, zs[None] + Z2, al, cmap="RdBu_r", vmin=-8, vmax=8, shading="auto")
            ax.contour(S2, zs[None] + Z2, al, [0], colors="k", linewidths=0.8)
            ax.fill_between(s_, zs.min() - 50, zs, color="#999")
            ax.set_title(f"хребет s = 0,5, λ = {d['lam_m']:.0f} м: u вдоль ветра, L/h = {d['L_over_h']:.1f}, угол {d['shadow_angle_deg']:.1f}°", fontsize=9)
            ax.set_ylabel("z, м")
            fig.colorbar(pc, ax=ax, label="м/с")
        axs[-1, 0].set_xlabel("по ветру, м")
        fig.tight_layout(); fig.savefig(HERE / "fig_lam_sections.png", dpi=110); plt.close(fig)


def clean(o):
    if isinstance(o, dict):
        return {k: clean(v) for k, v in o.items() if k != "sec"}
    if isinstance(o, (list, tuple)):
        return [clean(v) for v in o]
    if isinstance(o, (np.floating, float)):
        return None if not math.isfinite(float(o)) else round(float(o), 5)
    if isinstance(o, np.integer):
        return int(o)
    return o


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", default=str(DATA / "ap_probe"))
    ap.add_argument("--results")
    a = ap.parse_args()
    rdir = Path(a.results) if a.results else find_results(a.plan)
    P, lines, rows = load(a.plan, rdir)
    tight_rows = None
    tp = DATA / "ap_probe_t"
    tr = sorted(DATA.glob("ap_probe_t__*"))
    if tr and list(tr[-1].glob("part-*.h5")):
        _, _, tight_rows = load(tp, tr[-1])
    br = branch_part(rows, tight_rows)
    dm = dumax_part(rows, rdir, P)
    lam_res, lam_ref = lam_part(rows, P)
    lam_v, lam_rows = lam_verdict(lam_res)
    figs(br, dm, lam_res, lam_rows, rdir)
    with open(rdir / "run.jsonl") as f:
        runlog = [json.loads(l) for l in f]
    gpu_s = sum(r.get("wall_s", 0.0) for r in runlog if r.get("event") == "batch")
    summ = dict(plan=a.plan, results=str(rdir), n_cases=len(rows), n_plan=P["n_cases"], gpu_solve_seconds=gpu_s,
                branch=br["verdict"], lam_cause=lam_v,
                period_iters={k: e.get("period_iters") for k, e in dm.items()},
                branch_detail=br, dumax=dm, lam=dict(rows=lam_rows, ref_ap_v1_lam40=[dict(shape=k[0], s=k[1], **v) for k, v in lam_ref.items()],
                                                    literature=dict(L_over_h=LIT_L, ridge_angle_deg=LIT_ANGLE_RIDGE, S=[0.06, 0.11])))
    (HERE / "summary.json").write_text(json.dumps(clean(summ), ensure_ascii=False, indent=1))
    print(json.dumps(clean(dict(branch=br["verdict"], lam_cause=lam_v, period_iters=summ["period_iters"], gpu_s=gpu_s,
                                n_pairs=br["n_pairs"], n_conv=br["n_pairs_converged"], n_br=br["n_branch_converged"])), ensure_ascii=False))


if __name__ == "__main__":
    main()
