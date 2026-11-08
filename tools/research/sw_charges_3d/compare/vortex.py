"""SWD-5b: расчёт sim3d (вихревые нити с гребня, couple, restart) в постановке основного набора SWD-5 → строки vortex_jh.

Постановка та же, что у potential/potential_jh (compare/README.md): σ = 40 м, ds_min = 25 м, логарифмический фон, z0 = медиана растра,
фокус панелей в точках сравнения. Средние: точки rows — probes за t ≥ t_avg; ротор — по снимкам нитей (record_every) за t ≥ t_avg.
Вызывается из run_compare.py (`vortex`); кеш — out/compare/_cache/<case>_vortex_tau<tau>.json.
"""
from __future__ import annotations

import json
import math
import time

import numpy as np

import core as C
import panels3d as P
import sim3d
from sim3d.core import _Extra

TAU_MAIN = 60.0                       # с: выбран заранее (см. README): ~ полуширина гряды 500 м / U_ref ~ 8 м/с, порядок, не измерение
TAU_SCAN = (15.0, 30.0, 60.0, 120.0, 1.0e9)      # 1e9 — без затухания (ограничитель только gamma_min и t_end)
CORE = C.DS_MAIN                      # м: ядро новых нитей = ds_min (решение исполнителя; умолчание sim3d ds_min/2; число узлов от ядра не зависит)
GAMMA_MIN = 1.0                       # м²/с: нить слабее удаляется (иначе число узлов не ограничено; решение исполнителя, README)
DT = 3.0                              # с: шаг связки (сход каждый шаг при U_ref·dt ≥ 2·core); шаг sim3d ≈ 9 с при N 18 тыс. (панели), поэтому dt не меньше
T_END = 120.0                         # с: пролёт воздуха U_ref ≈ 7–12 м/с — 1–2 км; окно усреднения — вторая половина
N_SNAP = 8                            # снимков нитей в окне усреднения (ротор)
LEVELS = np.arange(15.0, 601.0, 15.0)


def tau_name(tau):
    return "inf" if tau >= 1e8 else f"{tau:g}"


def cache_file(case, tau):
    return C.CACHE / f"{case}_vortex_tau{tau_name(tau)}.json"


def _mean_vel(setup, snaps, x, y, z):
    """Среднее (u, v, w) velocity_jh с нитями по снимкам; время одного снимка — в мкс на точку."""
    acc = 0.0
    t0 = time.time()
    for s in snaps:
        ex = _Extra(s["filaments"], setup.panels) if len(s["filaments"].seg) else None
        u, v, w = P.velocity_jh(setup.panels, s["sigma"], setup.bg, x, y, z, setup.z0, U_ref=setup.U_ref, extra=ex,
                                infl=setup.infl, couple=setup.couple)
        acc = acc + np.stack([u, v, w], 1)
    return acc / len(snaps), 1e6 * (time.time() - t0) / (len(snaps) * len(x))


def rotor_snap(setup, snaps, wt, tr, u_scale):
    """Критерий SWD5 (как C.rotor_scan): u∥ < −0,5 м/с на z_agl 15 м, шаг 10 м, участок > 50 м; глубина — связная область
    выше (уровни 15 м … 600 м шаг 15 м) считается только в колонках лучшего участка. Возвращает (present, L, depth, u∥ min на 15 м)."""
    ex, ey = wt
    L = math.hypot(tr["x1"] - tr["x0"], tr["y1"] - tr["y0"])
    n = int(L // 10) + 1
    s = np.linspace(0, L, n)
    X = tr["x0"] + (tr["x1"] - tr["x0"]) * s / L
    Y = tr["y0"] + (tr["y1"] - tr["y0"]) * s / L
    h = setup.panels.height(X, Y)
    m, _ = _mean_vel(setup, snaps, X, Y, h + 15.0)
    upar0 = (m[:, 0] * ex + m[:, 1] * ey) * u_scale
    umin = float(np.nanmin(upar0))
    row0 = np.isfinite(upar0) & (upar0 < -0.5)
    best, bi, i = 0.0, None, 0
    while i < n:
        if row0[i]:
            j = i
            while j + 1 < n and row0[j + 1]:
                j += 1
            ln = (j - i + 1) * 10.0
            if ln > 50.0 and ln > best:
                best, bi = ln, (i, j)
            i = j + 1
        else:
            i += 1
    if bi is None:
        return False, 0.0, 0.0, umin
    ci = np.arange(bi[0], bi[1] + 1)
    nc = len(ci)
    XX, YY = np.tile(X[ci], len(LEVELS) - 1), np.tile(Y[ci], len(LEVELS) - 1)
    ZZ = setup.panels.height(XX, YY) + np.repeat(LEVELS[1:], nc)
    mm, _ = _mean_vel(setup, snaps, XX, YY, ZZ)
    up = ((mm[:, 0] * ex + mm[:, 1] * ey) * u_scale).reshape(len(LEVELS) - 1, nc)
    depth = 15.0
    for k in range(len(LEVELS) - 1):
        if not (np.isfinite(up[k]) & (up[k] < -0.5)).any():
            break
        depth = LEVELS[k + 1]
    return True, best, float(depth), umin


def build(case, refs):
    """Сетка, LU и Setup один раз на случай (старт на загруженном GPU — десятки минут): затем несколько tau_s подряд."""
    run = C.Run(case, refs=refs)
    run.free()
    st = sim3d.Setup(run.terrain, run.panels, run.bg, run.z0, dict(fil=dict(), core=CORE, couple=True, restart=True))
    return dict(run=run, st=st)


def simulate(case, refs, tau, t_end=T_END, dt=DT, make_rows=None, norm_info=None, fnum=None, metrics=None, ctx=None):
    """Один расчёт (случай, tau_s) → dict с rows, rotor, timing, summary (кешируется в json)."""
    cf = cache_file(case, tau)
    if cf.exists():
        return json.load(open(cf))
    t_all = time.time()
    if ctx is None:
        ctx = build(case, refs)
    run, st = ctx["run"], ctx["st"]
    t_asm0 = run.info["t_assemble_s"]
    st.fil["tau_s"] = float(tau)
    st.fil["gamma_min"] = GAMMA_MIN
    x, y, z = run.points()
    pr = np.stack([x, y, z], 1)
    t_avg = 0.5 * t_end
    rec = max(1, int(round((t_end - t_avg) / dt / N_SNAP)))
    res = sim3d.run(st, t_end, dt, t_avg=t_avg, probes=pr, record_every=rec)
    S = res["stats"]
    snaps = [s for s in res["snapshots"] if s["t"] >= t_avg - 1e-9]
    # точки rows
    f = {k: tuple(float(v) for v in res["probes_mean"]["vortex_jh"][i]) for i, k in enumerate(run.keys)}
    fj = {k: tuple(float(v) for v in res["probes_mean"]["potential_jh"][i]) for i, k in enumerate(run.keys)}
    rows = make_rows(run, "vortex_jh", f, refs)
    rows_j = make_rows(run, "potential_jh", fj, refs)
    # ротор
    nkey, Ud = norm_info(case, refs)
    sn = C.hspeed(f, nkey)
    rr = [r for r in refs["rotor"] if r["case"] == case]
    rotor = []
    t_q = []
    for tr in [t for t in refs["transects"] if t["case"] == case]:
        present, L, depth, umin = rotor_snap(st, snaps, run.wt, tr, Ud / sn)
        men = [r for r in rr if r["transect"] == tr["name"] and r["source"] == "menke2019"]
        pic = [r for r in rr if r["transect"] == tr["name"] and r["source"] == "picard_nom"]
        ref = (men or pic or [None])[0]
        rotor.append(dict(case=case, transect=tr["name"], variant="vortex_jh", present=bool(present), L_m=float(L), depth_m=float(depth),
                          L_ref=ref["L_m"] if ref else None,
                          ref_source=(ref["source"] + ": " + (ref["ref_source"] or "")[:120]) if ref else "нет эталона",
                          u_par_min_15m=float(umin), u_par_min_over_U=float(umin / Ud)))
    # время запроса
    _, tq = _mean_vel(st, snaps[:1], x, y, z)
    win = [s for s in S if s["t"] > t_avg]
    early = [s for s in S if s["t"] <= 10.0 + dt]
    # вклад нитей в поле: |Δ|s| / s между vortex_jh и potential_jh в точках rows (скорость относительно опорной точки)
    dv = []
    for a, b in zip(rows, rows_j):
        if a["s_pan"] is not None and b["s_pan"]:
            dv.append(dict(point=a["point"], z_agl=a["z_agl"], name=a["name"], ref_kind=a["ref_kind"], rel=(a["s_pan"] - b["s_pan"]) / b["s_pan"]))
    summ = dict(
        case=case, tau_s=float(tau), t_end=t_end, dt=dt, N=int(run.N), U_ref=st.U_ref, core=st.core, sep_every=max(1, int(round(2.0 * st.core / (st.U_ref * dt)))),
        n_nodes_end=S[-1]["n_nodes"], n_seg_end=S[-1]["n_seg"], n_nodes_max=max(s["n_nodes"] for s in S), n_seg_max=max(s["n_seg"] for s in S),
        gamma_abs_end=S[-1]["gamma_abs"], imbalance_max=max(s["imbalance"] for s in S),
        t_step_median=float(np.median([s["t_step"] for s in S])), t_step_last=S[-1]["t_step"], t_step_max=max(s["t_step"] for s in S),
        substeps_max=max(s["substeps"] for s in S),
        n_sep_win=float(np.mean([s["n_sep"] for s in win])) if win else None,
        n_sep_early=float(np.mean([s["n_sep"] for s in early if s["n_lines"] or s["n_sep"]])) if any(s["n_lines"] or s["n_sep"] for s in early) else None,
        n_reattach_sum=int(sum(s["n_reattach"] for s in S)),
        n_lines_sum=int(sum(s["n_lines"] for s in S)), n_skipped_sum=int(sum(s["n_skipped"] for s in S)),
        n_sep_by_step=[int(s["n_sep"]) for s in S], n_reattach_by_step=[int(s["n_reattach"]) for s in S], n_nodes_by_step=[int(s["n_nodes"]) for s in S],
        f_reconnect=int(S[-1].get("f_reconnect", 0)), f_split=int(S[-1].get("f_split", 0)), f_merge=int(S[-1].get("f_merge", 0)),
        f_lifted=int(S[-1].get("f_lifted", 0)), f_removed=int(S[-1].get("f_removed", 0)), n_snapshots=len(snaps), dv=dv)
    timing = dict(case=case, variant="vortex_jh", N=int(run.N), t_assemble_s=float(st.infl.t_assemble_s), t_solve_s=float(run.info["t_solve_s"]),
                  t_query_us=float(tq), t_run_s=time.time() - t_all, backend=st.infl.backend)
    out = dict(rows=rows, rows_j=[dict(point=r["point"], name=r["name"], z_agl=r["z_agl"], s_pan=r["s_pan"], u_par_pan=r["u_par_pan"]) for r in rows_j],
               rotor=rotor, timing=timing, summary=summ, metrics={k: fnum(v) for k, v in metrics(rows).items()})
    C.CACHE.mkdir(parents=True, exist_ok=True)
    json.dump(out, open(cf, "w"), allow_nan=False)
    return out
