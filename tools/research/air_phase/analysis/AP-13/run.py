#!/usr/bin/env python3
"""AP-13: порог несходимости N_c(U) без нагрева (AP-7: U_sat/N_c ≈ 335–444 м) — физика или решатель.

Одна команда, только CPU, данные только читаются:
  PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
  $PY tools/research/air_phase/analysis/AP-13/run.py
Вход: $AIR_SYNTH_DATA/phase/ap_v3 (план P2 v5, серия FIXED_U, построитель plan_build.py --series threshold)
      и $AIR_SYNTH_DATA/phase/ap_v3__<solver_version> (P3: части, trace).
Выход: summary.json, tables.md, fig_*.png рядом со скриптом.

Что считается:
  1. N_c по вариантам (ctrl, long, omega, kfloor, top4500, top6000, top4500_sp2000) и ветрам U_sat 3/4,5/6 —
     порог по lg N с наименьшим числом ошибок (несходимость = status ≠ 0), вилка — соседние точки сетки по N.
  2. Сдвиг lg N_c варианта против контроля в шагах сетки; показатель N_c ∝ U^p по трём ветрам.
  3. Поздняя динамика длинного счёта (3000 итераций, снимки каждые 10): тренд du_max, главная ЭОФ поля u(600 м)
     по поздним снимкам, её период (АКФ/спектр), где сидит изменчивость (у хребта / у боковых губок / у потолка не видно —
     снимки только на 25 и 600 м), горизонтальная длина волны изменчивости против 2πU/N.
"""
import glob
import json
import os
import sys

import h5py
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
D = os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data"))
PLAN = f"{D}/phase/ap_v3"
RES = sorted(glob.glob(f"{D}/phase/ap_v3__s*"))
VARIANTS = ["ctrl", "long", "omega", "kfloor", "top4500", "top6000", "top4500_sp2000"]
USATS = [3.0, 4.5, 6.0]
DX = 400.0
SIDE_CELLS = 5            # боковая губка 2000 м = 5 клеток
H_M, BASE_M = 500.0, 1000.0
OUT, TAB = {}, []


def tab(title, header, rows):
    TAB.append(f"\n### {title}\n\n| " + " | ".join(header) + " |\n|" + "---|" * len(header) + "\n"
               + "\n".join("| " + " | ".join(str(x) for x in r) + " |" for r in rows) + "\n")


def f3(x):
    return "—" if x is None or (isinstance(x, float) and not np.isfinite(x)) else f"{x:.3g}"


# ------------------------------------------------------------------------------------------------ данные
def load():
    plan = json.load(open(f"{PLAN}/plan.json"))
    lines = {int(l["line_id"]): l for l in plan["lines"]}
    if not RES:
        sys.exit("нет результатов ap_v3__*")
    res = RES[-1]
    rows, where = [], {}
    for fn in sorted(glob.glob(f"{res}/part-*.h5")):
        with h5py.File(fn, "r") as f:
            c = f["cases"][:]
            it, rs, du = f["trace/iter"][:], f["trace/resid"][:], f["trace/du_max"][:]
            for i in range(len(c)):
                ln = lines[int(c["line_id"][i])]
                nm = ln["numerics"]
                k = it[i] >= 0
                r = dict(case_id=int(c["case_id"][i]), variant=ln["variant"], u_sat=round(float(c["u_sat"][i]), 2),
                         n_bv=float(c["n_bv"][i]), fr=float(c["fr"][i]), status=int(c["status"][i]), iters=int(c["iters"][i]),
                         spread=float(c["late_spread60_p90"][i]), resid=float(c["resid_final"][i]),
                         max_outer=int(nm["max_outer"]), late_from=int(nm["late_from"]),
                         t_iter=it[i][k], t_resid=rs[i][k], t_du=du[i][k])
                rows.append(r)
                where[r["case_id"]] = (fn, i)
    rows.sort(key=lambda r: r["case_id"])
    OUT["n_cases"] = len(rows)
    OUT["n_plan"] = int(plan["n_cases"])
    OUT["results_dir"] = res
    return rows, where


# ------------------------------------------------------------------------------------------------ порог
def threshold(ns, nc):
    """Порог по lg N с наименьшим числом ошибок (выше порога — несходимость). → (N_c, N_lo, N_hi, ошибок, монотонно)."""
    o = np.argsort(ns)
    ns, nc = np.asarray(ns)[o], np.asarray(nc)[o].astype(int)
    cand = [(ns[0] / 1.05, -1)] + [(np.sqrt(ns[i] * ns[i + 1]), i) for i in range(len(ns) - 1)] + [(ns[-1] * 1.05, len(ns) - 1)]
    errs = [int(np.sum(nc[: i + 1]) + np.sum(1 - nc[i + 1:])) for _, i in cand]
    best = min(errs)
    idx = [j for j, e in enumerate(errs) if e == best]
    j = idx[len(idx) // 2]
    i = cand[j][1]
    lo = ns[i] if i >= 0 else np.nan
    hi = ns[i + 1] if i + 1 < len(ns) else np.nan
    mono = bool(np.all(np.diff(nc) >= 0))
    cens = "below_range" if i < 0 else ("above_range" if i + 1 >= len(ns) else "")
    return float(cand[j][0]), float(lo), float(hi), best, mono, cens


def thresholds(rows):
    tabrows, res = [], {}
    for v in VARIANTS:
        res[v] = {}
        for u in USATS:
            sel = [r for r in rows if r["variant"] == v and r["u_sat"] == u]
            if not sel:
                continue
            ns = np.array([r["n_bv"] for r in sel])
            nc = np.array([r["status"] != 0 for r in sel])
            nc_, lo, hi, e, mono, cens = threshold(ns, nc)
            pattern = "".join("x" if r["status"] else "." for r in sorted(sel, key=lambda r: r["n_bv"]))
            it_ok = [r["iters"] for r in sel if r["status"] == 0]
            res[v][str(u)] = dict(n_c_per_s=nc_, bracket_per_s=[lo, hi], errors=e, monotone=mono, n=len(sel),
                                  nonconv=int(nc.sum()), censored=cens, u_over_n_c_m=u / nc_, lambda_z_m=2 * np.pi * u / nc_,
                                  pattern_by_n=pattern, iters_ok_max=max(it_ok) if it_ok else None)
            tabrows.append([v, u, ("< " if cens == "below_range" else "> " if cens else "") + f"{nc_:.4f}", f"{lo:.4f}–{hi:.4f}", e, pattern, f"{u / nc_:.0f}", f"{2 * np.pi * u / nc_ / 1000:.2f}",
                            max(it_ok) if it_ok else "—"])
    tab("N_c по вариантам (x — не сошлось, точки по возрастанию N)", ["вариант", "U_sat", "N_c, 1/с", "вилка", "ошибок",
        "по N", "U/N_c, м", "λ_z, км", "итераций сошедшихся, max"], tabrows)
    # шаг сетки по lg N (одинаков для всех ветров при 11 точках)
    steps = {}
    for u in USATS:
        ns = sorted({r["n_bv"] for r in rows if r["u_sat"] == u})
        steps[str(u)] = float(np.mean(np.diff(np.log10(ns)))) if len(ns) > 1 else np.nan
    OUT["grid_step_decades"] = steps
    # сдвиги против контроля
    shift, srows = {}, []
    for v in VARIANTS[1:]:
        shift[v] = {}
        for u in USATS:
            a, b = res.get("ctrl", {}).get(str(u)), res.get(v, {}).get(str(u))
            if not a or not b:
                continue
            d = np.log10(b["n_c_per_s"] / a["n_c_per_s"])
            st = d / steps[str(u)]
            shift[v][str(u)] = dict(dlog10=float(d), steps=float(st), ratio=float(b["n_c_per_s"] / a["n_c_per_s"]))
            if b["censored"]:
                shift[v][str(u)]["censored"] = b["censored"]
            srows.append([v + (" (за краем сетки)" if b["censored"] else ""), u, f"{d:+.3f}", f"{st:+.1f}", f"{b['n_c_per_s'] / a['n_c_per_s']:.3f}"])
    tab("Сдвиг N_c против контроля", ["вариант", "U_sat", "Δ lg N_c", "шагов сетки", "N_c/N_c,ctrl"], srows)
    # показатель N_c ∝ U^p
    expo, erows = {}, []
    for v in VARIANTS:
        us = [u for u in USATS if str(u) in res.get(v, {})]
        if len(us) >= 2:
            x = np.log10(us)
            y = np.log10([res[v][str(u)]["n_c_per_s"] for u in us])
            p = np.polyfit(x, y, 1)
            expo[v] = dict(p=float(p[0]), n_winds=len(us))
            erows.append([v, f"{p[0]:.2f}", len(us)])
    tab("Показатель N_c ∝ U_sat^p", ["вариант", "p", "ветров"], erows)
    OUT["n_c"], OUT["shift_vs_ctrl"], OUT["exponent_n_c_vs_u"] = res, shift, expo
    return res, shift, steps


# ------------------------------------------------------------------------------------------------ поздняя динамика
def ridge_crest(hc):
    return int(np.argmax(hc[hc.shape[0] // 2]))


def late_dynamics(rows, where):
    """Длинный счёт: для каждого случая — тренд du_max, ЭОФ поздних снимков u(600), период, где изменчивость."""
    out, trows = {}, []
    sel = [r for r in rows if r["variant"] == "long"]
    keep = {}
    for r in sel:
        fn, i = where[r["case_id"]]
        with h5py.File(fn, "r") as f:
            it = f["trace/iter"][i]
            k = np.where(it >= 0)[0]
            if r["status"] == 0 or len(k) < 40:
                out[str(r["case_id"])] = dict(u_sat=r["u_sat"], n_bv=r["n_bv"], status=r["status"], iters=r["iters"])
                continue
            hc = f["inputs/hc"][i]
            late = k[it[k] >= 1500]
            U = f["trace/fields"][i, late, 0, 1].astype(np.float64)       # u на 600 м (snap, j, i)
            W = f["trace/fields"][i, late, 2, 1].astype(np.float64)
        its = it[late]
        du = r["t_du"]
        tt = r["t_iter"]
        # тренд du_max (снимки через 10 итераций): средние по третям 1000–3000
        m = tt >= 1000
        thirds = np.array_split(du[m], 3)
        trend = float(np.mean(thirds[2]) / max(np.mean(thirds[0]), 1e-12))
        A = U - U.mean(0)
        std = A.std(0)
        X = A.reshape(len(A), -1)
        uu, ss, vt = np.linalg.svd(X, full_matrices=False)
        ev1 = float(ss[0] ** 2 / np.sum(ss ** 2))
        pc = uu[:, 0] * ss[0]
        # АКФ и спектр PC1 (шаг 10 итераций)
        pcd = pc - np.polyval(np.polyfit(its, pc, 1), its)
        n = len(pcd)
        ac = np.correlate(pcd, pcd, "full")[n - 1:] / (np.sum(pcd ** 2) + 1e-30)
        # первая положительная вершина АКФ после первого нуля
        z = np.where(ac < 0)[0]
        per_acf, ac_peak = np.nan, np.nan
        if len(z):
            j0 = z[0]
            if j0 < n - 2:
                jp = j0 + int(np.argmax(ac[j0: n // 2])) if j0 < n // 2 else None
                if jp is not None:
                    per_acf, ac_peak = float(jp * 10), float(ac[jp])
        sp = np.abs(np.fft.rfft(pcd * np.hanning(n))) ** 2
        fr = np.fft.rfftfreq(n, d=10.0)
        jm = 1 + int(np.argmax(sp[1:]))
        per_fft = float(1 / fr[jm])
        sp_frac = float(sp[jm] / sp[1:].sum())
        # где изменчивость
        e = std ** 2
        tot = e.sum() + 1e-30
        ny, nx = e.shape
        side = np.zeros_like(e, bool)
        side[:SIDE_CELLS], side[-SIDE_CELLS:], side[:, :SIDE_CELLS], side[:, -SIDE_CELLS:] = True, True, True, True
        ic = ridge_crest(hc)
        xs = (np.arange(nx) - ic) * DX / 1000.0
        lee = np.zeros_like(e, bool)
        lee[:, ic: min(nx, ic + 25)] = True          # от гребня 10 км по ветру
        lee &= ~side
        up = np.zeros_like(e, bool)
        up[:, max(0, ic - 15): ic] = True             # 6 км перед гребнем
        up &= ~side
        jmax, imax = np.unravel_index(np.argmax(e * ~side), e.shape)
        # горизонтальная длина волны изменчивости: спектр по x пространственной ЭОФ1 (средней по средней трети хребта)
        eof = vt[0].reshape(ny, nx)
        prof = eof[ny // 2 - 12: ny // 2 + 12].mean(0)
        prof = prof[SIDE_CELLS: nx - SIDE_CELLS]
        ps = np.abs(np.fft.rfft((prof - prof.mean()) * np.hanning(len(prof)))) ** 2
        kf = np.fft.rfftfreq(len(prof), d=DX)
        jk = 1 + int(np.argmax(ps[1:]))
        lam_x = float(1 / kf[jk])
        lam_z = 2 * np.pi * r["u_sat"] / r["n_bv"]
        d = dict(u_sat=r["u_sat"], n_bv=r["n_bv"], status=r["status"], iters=r["iters"], spread_m_s=r["spread"],
                 du_late_mean_m_s=float(np.mean(du[tt >= 2000])), du_trend_last_over_first_third=trend,
                 resid_late=float(np.mean(r["t_resid"][tt >= 2000])),
                 eof1_var_frac=ev1, period_acf_iters=per_acf, acf_peak=ac_peak, period_fft_iters=per_fft, fft_peak_frac=sp_frac,
                 var_frac_side_sponge=float(e[side].sum() / tot), var_frac_lee_10km=float(e[lee].sum() / tot),
                 var_frac_upstream_6km=float(e[up].sum() / tot),
                 max_var_x_from_crest_km=float(xs[imax]), max_var_y_km=float((jmax - ny / 2) * DX / 1000), std_u600_max_m_s=float(std.max()),
                 lambda_x_eof1_m=lam_x, lambda_z_m=lam_z)
        out[str(r["case_id"])] = d
        keep[r["case_id"]] = dict(std=std, eof=eof, pc=pc, its=its, tt=tt, du=du, xs=xs, W=W.std(0))
        trows.append([r["u_sat"], f"{r['n_bv']:.4f}", f"{r['spread']:.2f}", f"{d['du_trend_last_over_first_third']:.2f}",
                      f"{ev1:.2f}", f3(per_acf), f3(ac_peak), f"{per_fft:.0f}", f"{sp_frac:.2f}",
                      f"{d['var_frac_lee_10km']:.2f}", f"{d['var_frac_upstream_6km']:.2f}", f"{d['var_frac_side_sponge']:.2f}",
                      f"{d['max_var_x_from_crest_km']:+.1f}", f"{lam_x / 1000:.1f}", f"{lam_z / 1000:.1f}"])
    tab("Поздняя динамика длинного счёта (несошедшиеся; снимки 1500–3000, шаг 10 итераций; u на 600 м)",
        ["U_sat", "N", "разброс, м/с", "du: 3-я/1-я треть", "доля ЭОФ1", "период АКФ, итер", "АКФ в вершине", "период спектра, итер",
         "доля пика", "дисп. у хребта (0…10 км)", "перед хребтом (−6…0)", "в боковых губках", "x max дисп., км", "λ_x ЭОФ1, км",
         "2πU/N, км"], trows)
    OUT["late_long"] = out
    return out, keep


def long_vs_ctrl(rows):
    """Сходятся ли несошедшиеся контроля за 3000 итераций; совпадают ли статусы/итерации на 1000 у long и ctrl."""
    c = {(r["u_sat"], round(r["n_bv"], 6)): r for r in rows if r["variant"] == "ctrl"}
    lg = {(r["u_sat"], round(r["n_bv"], 6)): r for r in rows if r["variant"] == "long"}
    same, late_conv, still = 0, [], 0
    for k, a in c.items():
        b = lg.get(k)
        if b is None:
            continue
        if a["status"] == 0:
            same += int(b["status"] == 0 and b["iters"] == a["iters"])
        else:
            if b["status"] == 0:
                late_conv.append(dict(u_sat=k[0], n_bv=k[1], iters_long=b["iters"]))
            else:
                still += 1
    nconv = sum(a["status"] == 0 for a in c.values())
    OUT["long_vs_ctrl"] = dict(ctrl_conv=nconv, long_same_iters_of_ctrl_conv=same, ctrl_nonconv_converged_by_3000=late_conv,
                               ctrl_nonconv_still_nonconv_3000=still)


def omega_detail(rows):
    """ω = 0,5 при 2000 итерациях: сколько несходимостей контроля исчезает; итерации сошедшихся."""
    c = {(r["u_sat"], round(r["n_bv"], 6)): r for r in rows if r["variant"] == "ctrl"}
    out = {}
    for v in VARIANTS[1:]:
        cured, broken = 0, 0
        for r in rows:
            if r["variant"] != v:
                continue
            a = c.get((r["u_sat"], round(r["n_bv"], 6)))
            if a is None:
                continue
            cured += int(a["status"] != 0 and r["status"] == 0)
            broken += int(a["status"] == 0 and r["status"] != 0)
        out[v] = dict(cured=cured, broken=broken)
    OUT["cured_broken_vs_ctrl"] = out
    tab("Против контроля по точкам", ["вариант", "вылечено", "испорчено"], [[v, d["cured"], d["broken"]] for v, d in out.items()])


def spreads(rows):
    """Разброс поздних итераций у несошедшихся по вариантам (медиана) — амплитуда блуждания."""
    t = []
    d = {}
    for v in VARIANTS:
        for u in USATS:
            s = [r["spread"] for r in rows if r["variant"] == v and r["u_sat"] == u and r["status"] != 0]
            if s:
                d[f"{v}_{u}"] = dict(median_m_s=float(np.median(s)), n=len(s))
                t.append([v, u, len(s), f"{np.median(s):.3f}", f"{np.max(s):.3f}"])
    OUT["late_spread_nonconv"] = d
    tab("Разброс поздних итераций у несошедшихся (late_spread60_p90, м/с)", ["вариант", "U_sat", "n", "медиана", "max"], t)


def fixed_point(rows, where):
    """Та ли же неподвижная точка: где сошлись и контроль, и вариант — max|Δu|, max|Δv| по 13 высотам / U_sat."""
    def fld(cid):
        fn, i = where[cid]
        with h5py.File(fn, "r") as f:
            return f["fields/f"][i, :2].astype(np.float64)
    c = {(r["u_sat"], round(r["n_bv"], 6)): r for r in rows if r["variant"] == "ctrl" and r["status"] == 0}
    out, t, pairs = {}, [], []
    nc = {u: d["n_c_per_s"] for u, d in OUT["n_c"]["ctrl"].items()}
    for v in VARIANTS[1:]:
        d = []
        for r in rows:
            a = c.get((r["u_sat"], round(r["n_bv"], 6)))
            if r["variant"] == v and r["status"] == 0 and a is not None:
                d.append(float(np.abs(fld(r["case_id"]) - fld(a["case_id"])).max() / r["u_sat"]))
                pairs.append(dict(variant=v, u_sat=r["u_sat"], n_over_n_c_ctrl=r["n_bv"] / nc[str(r["u_sat"])], du_over_u=d[-1]))
        if d:
            out[v] = dict(n=len(d), max_du_over_u=float(np.max(d)), median_du_over_u=float(np.median(d)))
            t.append([v, len(d), f"{np.median(d):.3g}", f"{np.max(d):.3g}"])
    OUT["fixed_point_vs_ctrl"] = out
    OUT["fixed_point_pairs"] = pairs
    tab("Сошедшиеся решения против контроля (та же точка, max|Δu,Δv| по 13 высотам / U_sat)", ["вариант", "пар", "медиана", "max"], t)


def calm():
    """План ap_v3_calm (по ревью AP-9): штиль Fr 0,15–0,25 (N 0,01, h 500), контроль и ω = 0,3, 2000 итераций."""
    res = sorted(glob.glob(f"{D}/phase/ap_v3_calm__s*"))
    if not res:
        return
    plan = json.load(open(f"{D}/phase/ap_v3_calm/plan.json"))
    lines = {int(l["line_id"]): l for l in plan["lines"]}
    rs = []
    for fn in sorted(glob.glob(f"{res[-1]}/part-*.h5")):
        with h5py.File(fn, "r") as f:
            c = f["cases"][:]
            it, du, rr = f["trace/iter"][:], f["trace/du_max"][:], f["trace/resid"][:]
            for i in range(len(c)):
                k = it[i] >= 0
                tt, dd, re = it[i][k], du[i][k], rr[i][k]
                m1, m2 = (tt >= 1000) & (tt < 1500), tt >= 1500
                rs.append(dict(variant=lines[int(c["line_id"][i])]["variant"], fr=round(float(c["fr"][i]), 3), u_sat=float(c["u_sat"][i]),
                               status=int(c["status"][i]), iters=int(c["iters"][i]), spread_m_s=float(c["late_spread60_p90"][i]),
                               resid_late=float(re[m2].mean()) if m2.any() else None,
                               resid_trend=float(re[m2].mean() / re[m1].mean()) if m1.any() and m2.any() else None))
    rs.sort(key=lambda r: (r["variant"], r["fr"]))
    OUT["calm"] = rs
    tab("Штиль (ap_v3_calm): Fr 0,15–0,25, N = 0,01, h = 500, хребет, H = 0, 2000 итераций", ["вариант", "Fr", "U_sat",
        "статус", "итераций", "разброс, м/с", "невязка 1500–2000", "невязка: 1500–2000 / 1000–1500"],
        [[r["variant"], r["fr"], f"{r['u_sat']:.2f}", r["status"], r["iters"], f"{r['spread_m_s']:.3f}", f3(r["resid_late"]),
          f3(r["resid_trend"])] for r in rs])


# ------------------------------------------------------------------------------------------------ рисунки
def figs(rows, res, late, keep):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    col = dict(ctrl="k", long="0.5", omega="tab:blue", kfloor="tab:green", top4500="tab:orange", top6000="tab:red",
               top4500_sp2000="tab:purple")
    # 1. несходимость по N, по ветрам, варианты — ряды
    fig, axs = plt.subplots(1, 3, figsize=(13, 4.5))
    for ax, u in zip(axs, USATS):
        for j, v in enumerate(VARIANTS):
            sel = sorted([r for r in rows if r["variant"] == v and r["u_sat"] == u], key=lambda r: r["n_bv"])
            ns = [r["n_bv"] for r in sel]
            ax.scatter(ns, [j] * len(ns), c=["tab:red" if r["status"] else "tab:green" for r in sel], s=28)
            nc = res.get(v, {}).get(str(u))
            if nc:
                ax.plot([nc["n_c_per_s"]] * 2, [j - 0.4, j + 0.4], color=col[v], lw=2)
        ax.set_xscale("log"); ax.set_yticks(range(len(VARIANTS))); ax.set_yticklabels(VARIANTS)
        ax.set_title(f"U_sat = {u} м/с (зел. — сошлось, красн. — нет; черта — N_c)"); ax.set_xlabel("N, 1/с")
    fig.tight_layout(); fig.savefig(f"{HERE}/fig_status_by_n.png", dpi=110); plt.close(fig)
    # 2. N_c(U) по вариантам
    fig, ax = plt.subplots(figsize=(6, 4.5))
    for v in VARIANTS:
        us = [u for u in USATS if str(u) in res.get(v, {})]
        ax.plot(us, [res[v][str(u)]["n_c_per_s"] for u in us], "o-", color=col[v], label=v)
    uu = np.linspace(3, 6, 20)
    ax.plot(uu, 0.0089 * (uu / 3) ** 0.6, "k:", label="AP-7: 0,0089·(U/3)^0,6")
    ax.set_xscale("log"); ax.set_yscale("log"); ax.set_xlabel("U_sat, м/с"); ax.set_ylabel("N_c, 1/с"); ax.legend(fontsize=7)
    fig.tight_layout(); fig.savefig(f"{HERE}/fig_nc_vs_u.png", dpi=110); plt.close(fig)
    if not keep:
        return
    # 3. du_max и PC1 длинного счёта у порога (по одному случаю на ветер — ближайший к N_c сверху и самый дальний)
    picks = []
    for u in USATS:
        cs = sorted([(cid, late[str(cid)]) for cid in keep if late[str(cid)]["u_sat"] == u], key=lambda x: x[1]["n_bv"])
        if cs:
            picks += [cs[0], cs[-1]] if len(cs) > 1 else [cs[0]]
    fig, axs = plt.subplots(2, 1, figsize=(10, 7))
    for cid, d in picks:
        k = keep[cid]
        lab = f"U {d['u_sat']}, N {d['n_bv']:.4f}"
        axs[0].semilogy(k["tt"], k["du"], lw=0.8, label=lab)
        axs[1].plot(k["its"], k["pc"], lw=0.8, label=lab)
    axs[0].set_ylabel("du_max за 10 итераций, м/с"); axs[1].set_ylabel("PC1 u(600 м), м/с"); axs[1].set_xlabel("итерация")
    axs[0].legend(fontsize=7); fig.tight_layout(); fig.savefig(f"{HERE}/fig_late_traces.png", dpi=110); plt.close(fig)
    # 4. карты СКО поздних u(600 м) и ЭОФ1 для двух случаев
    fig, axs = plt.subplots(2, max(2, len(picks[:4])), figsize=(4 * max(2, len(picks[:4])), 7.5))
    for j, (cid, d) in enumerate(picks[:4]):
        k = keep[cid]
        ext = [k["xs"][0], k["xs"][-1], -19.2, 19.2]
        im = axs[0, j].imshow(k["std"], origin="lower", extent=ext, cmap="magma"); plt.colorbar(im, ax=axs[0, j], shrink=0.7)
        axs[0, j].set_title(f"СКО u600, U {d['u_sat']} N {d['n_bv']:.4f}", fontsize=8)
        im = axs[1, j].imshow(k["eof"], origin="lower", extent=ext, cmap="RdBu_r"); plt.colorbar(im, ax=axs[1, j], shrink=0.7)
        axs[1, j].set_title(f"ЭОФ1 ({d['eof1_var_frac']:.0%}), x от гребня, км", fontsize=8)
    fig.tight_layout(); fig.savefig(f"{HERE}/fig_late_maps.png", dpi=100); plt.close(fig)


# ------------------------------------------------------------------------------------------------ вывод
def verdict(res, shift, steps, late):
    def sig(v):
        """Сдвиг значим при |Δ| ≥ 1,5 шага сетки; → (число значимых ветров, средний Δ в шагах)."""
        s = shift.get(v, {})
        st = [x["steps"] for x in s.values()]
        return sum(abs(x) >= 1.5 for x in st), float(np.mean(st)) if st else np.nan
    flags = {v: dict(zip(("n_sig_winds", "mean_shift_steps"), sig(v))) for v in VARIANTS[1:]}
    top_sig = max(flags[v]["n_sig_winds"] for v in ("top4500", "top6000", "top4500_sp2000"))
    om_sig = flags["omega"]["n_sig_winds"]
    kf_sig = flags["kfloor"]["n_sig_winds"]
    lg_sig = flags["long"]["n_sig_winds"]
    nl = [d for d in late.values() if "var_frac_lee_10km" in d]
    lee = float(np.median([d["var_frac_lee_10km"] + d["var_frac_upstream_6km"] for d in nl])) if nl else np.nan
    side = float(np.median([d["var_frac_side_sponge"] for d in nl])) if nl else np.nan
    trend = float(np.median([d["du_trend_last_over_first_third"] for d in nl])) if nl else np.nan
    solver_evidence = top_sig >= 2 or om_sig >= 2 or lg_sig >= 2
    physics_evidence = top_sig == 0 and om_sig == 0 and lg_sig == 0
    if solver_evidence and not (lee > 0.5 and top_sig == 0):
        cause = "solver"
    elif physics_evidence:
        cause = "physics"
    else:
        cause = "mixed"
    OUT["flags"] = flags
    OUT["late_median"] = dict(var_frac_near_ridge=lee, var_frac_side_sponge=side, du_trend=trend, n_cases=len(nl))
    return cause


def main():
    rows, where = load()
    res, shift, steps = thresholds(rows)
    long_vs_ctrl(rows)
    omega_detail(rows)
    spreads(rows)
    fixed_point(rows, where)
    calm()
    late, keep = late_dynamics(rows, where)
    OUT["threshold_cause"] = verdict(res, shift, steps, late)
    OUT["n_c_per_s_by_variant"] = {v: {u: d["n_c_per_s"] for u, d in res[v].items()} for v in res}
    OUT["contract"], OUT["task"] = "P7 v1", "AP-13"
    figs(rows, res, late, keep)
    json.dump(OUT, open(f"{HERE}/summary.json", "w"), ensure_ascii=False, indent=1, default=float)
    open(f"{HERE}/tables.md", "w").write("# AP-13: таблицы (генерирует run.py)\n" + "".join(TAB))
    print("".join(TAB))
    print("threshold_cause", OUT["threshold_cause"], json.dumps(OUT["flags"], ensure_ascii=False))
    print(json.dumps(OUT["long_vs_ctrl"], ensure_ascii=False), json.dumps(OUT["late_median"], ensure_ascii=False))


if __name__ == "__main__":
    main()
