#!/usr/bin/env python3
"""VM-3: переворот при отпускании штанги с Vmax — замер Cmq прототипа, одна поправка pitch.cm_q_add, 48 крыльев.

Модель — VM-2 (vm2_run.py: pitch_nl σ 0,5, w 1°, luff 0,02/°, Δ_l 0°) с добором arms.shift_x_pull_full_m = 0,7 м
(VM-К4 v2, руководство T2C), shift_x_pull_m 0,45, force_max_n 300. Постановка — как vm2_run.py (GameSim, рыскание
свободно, шаг 1/120 с, эталонная масса, штиль). Варианты:
  base — прежняя модель (ход 0,45 м, линейный тангаж);  nl — VM-2 с добором 0,7 м;  fix — nl + cm_q_add (CMQ_ADD).

  $PY tools/research/pendulum/vm3_run.py cmq [--jobs 12]        → out/vm3/cmq.json (Cmq полос, системы, литература)
  $PY tools/research/pendulum/vm3_run.py diag --wings a,b [--var nl] → out/vm3/diag/<крыло>_<вариант>.npz + diag.json
  $PY tools/research/pendulum/vm3_run.py run [--jobs 12]        → out/vm3/results.jsonl (продолжает)
  $PY tools/research/pendulum/vm3_run.py report                 → out/vm3/summary.json (VM-К4 v2), tables.md, fig/
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
import traceback
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import export_reference as E  # noqa: E402
import vm2_run as V2  # noqa: E402
from pendulum import pilot_body, trim  # noqa: E402
from pendulum.model import Control  # noqa: E402
from pendulum.params import G  # noqa: E402
from pendulum.scenarios import run  # noqa: E402

OUT = HERE / "out" / "vm3"
D, RAD = math.degrees, math.radians
WINGS = V2.WINGS
PULL_NORMAL = 0.45
PULL_FULL = 0.7  # VM-К4 v2: «штанга у бёдер» по руководству T2C
ARMS_FORCE_MAX = 300.0
# Cmq литературы (Hiway Demon на триме 10,8 м/с, «Experimental» = модель Cook & Spottiswoode 2005, American форма,
# на q·c̄/2V, около ЦМ системы): −1,11; расчёт Kochi 2020 — −0,891. Поправка = литература − замер полос (cmq.json).
CMQ_LIT = -1.11
CMQ_ADD = float("nan")  # заполняется из out/vm3/cmq.json (cmd_cmq), см. _load_cmq_add
NL = dict(V2.NL, pull_full=PULL_FULL, force_max=ARMS_FORCE_MAX)
DIAG_WINGS = ["training", "laminar", "sport", "ww_t2c", "moyes_litespeed_rx"]


def _load_cmq_add():
    p = OUT / "cmq.json"
    if p.exists():
        return float(json.loads(p.read_text())["cm_q_add"])
    return float("nan")


def make(wing, var):
    if var == "base":
        return V2.make(wing, "base")
    nl = dict(NL)
    if var.startswith("q="):
        # чувствительность (не правка): cm_q_add задан явно, напр. «q=-2»
        nl["cm_q_add"] = float(var[2:])
        return V2.make(wing, "nl", nl=nl)
    if var == "fix":
        add = _load_cmq_add()
        if not math.isfinite(add):
            raise RuntimeError("нет out/vm3/cmq.json: сначала vm3_run.py cmq")
        nl["cm_q_add"] = add
    return V2.make(wing, "nl", nl=nl)


# ----------------------------------------------------------------------------- Cmq
def _cm(s, pos, vel, R, w):
    _, M, _ = s.wing_aero(pos, vel, R, w)
    return M


def cmq_wing(s):
    """Cmq полос около ЦМ крыла на триме (статика): dCm/d(q·c/2V), конечная разность ±0,01."""
    st = s.trim_state
    V, R = st["V"], np.array(st["R"])
    vel = np.array(st["vel"])
    c, qd = s.p.chord_mean, 0.5 * s.p.rho * V * V * s.p.area * s.p.chord_mean
    out = []
    for qh in (-0.01, 0.01):
        w = R @ np.array([0.0, qh * 2 * V / c, 0.0])
        out.append((R.T @ _cm(s, np.zeros(3), vel, R, w))[1] / qd)
    return (out[1] - out[0]) / 0.02


def cmq_system(s):
    """Cmq системы «крыло + пилот» как одного твёрдого тела около общего ЦМ (как в модели Cook): полосы с ω и
    скоростью ЦМ крыла от вращения около общего ЦМ, плюс сопротивление пилота (точка) на своём плече."""
    st = s.trim_state
    p = s.p
    V, R = st["V"], np.array(st["R"])
    vel = np.array(st["vel"])
    d_b = np.array(st["pilot_dir_b"])
    H = R @ s.r_hang_b
    xp = H + R @ d_b * p.hang_len
    cg = (p.m_wing * np.zeros(3) + p.m_pilot * xp) / p.m_total
    c, qd = p.chord_mean, 0.5 * p.rho * V * V * p.area * p.chord_mean
    out = []
    for qh in (-0.01, 0.01):
        w = R @ np.array([0.0, qh * 2 * V / c, 0.0])
        vw = vel + np.cross(w, -cg)
        F, M, _ = s.wing_aero(np.zeros(3), vw, R, w)
        vp = vel + np.cross(w, xp - cg)
        fp, mp = pilot_body.pilot_force(p, vp, w, R, xp - H)
        Mt = M + mp + np.cross(-cg, F) + np.cross(xp - cg, fp)
        out.append((R.T @ Mt)[1] / qd)
    return (out[1] - out[0]) / 0.02, float(np.linalg.norm(cg))


def cmq_job(wing):
    s = make(wing, "nl")
    cw = cmq_wing(s)
    cs, h_cg = cmq_system(s)
    p = s.p
    st = s.trim_state
    V = st["V"]
    # частота и затухание собственного тангажа крыла около подвески (крыло на неподвижной подвеске):
    # жёсткость по α около подвески — Kn·CLα·q̄Sc, инерция Iyy + m_w·|r_H|², демпфирование −Cmq·q̄Sc²/(2V)
    rH = float(np.linalg.norm(s.r_hang_b))
    Iy = float(s.I_b[1, 1]) + p.m_wing * rH * rH
    kn = trim.static_margin(s, st["alpha"], V)
    g = V2.load_geom()[wing] if (V2.OUT / "geom.json").exists() else None
    cla = g["cl_alpha"] if g else 4.5
    qd = 0.5 * p.rho * V * V * p.area * p.chord_mean
    k = kn * cla * qd
    cdamp = -cw * qd * p.chord_mean / (2 * V)
    return {"wing": wing, "V_trim": V, "cmq_wing": cw, "cmq_system": cs, "h_cg_m": h_cg, "Iyy_wing": float(s.I_b[1, 1]),
            "Iyy_hang": Iy, "chord_mean": p.chord_mean, "area": p.area, "kn": kn, "cl_alpha": cla,
            "zeta_wing_trim": cdamp / (2 * math.sqrt(k * Iy)) if k > 0 else float("nan"),
            "omega_wing_trim": math.sqrt(k / Iy) if k > 0 else float("nan")}


def cmd_cmq(args):
    OUT.mkdir(parents=True, exist_ok=True)
    with ProcessPoolExecutor(args.jobs) as ex:
        rows = list(ex.map(cmq_job, WINGS))
    cs = np.array([r["cmq_system"] for r in rows])
    cw = np.array([r["cmq_wing"] for r in rows])
    demon = [r for r in rows if r["wing"] in ("ww_spectrum", "training")]
    # одна поправка на парк: литература (около ЦМ системы) минус медиана замера системы прототипа
    add = CMQ_LIT - float(np.median(cs))
    res = {"cmq_lit": CMQ_LIT, "cmq_lit_estimated": -0.891, "cmq_wing_median": float(np.median(cw)),
           "cmq_wing_min": float(cw.min()), "cmq_wing_max": float(cw.max()), "cmq_system_median": float(np.median(cs)),
           "cmq_system_min": float(cs.min()), "cmq_system_max": float(cs.max()), "cm_q_add": round(add, 3),
           "rows": rows, "note": "Cmq на q·c̄/2V (c̄ = S/b); около ЦМ крыла (полосы) и около общего ЦМ (твёрдая система)"}
    tmp = OUT / "cmq.json.tmp"
    tmp.write_text(json.dumps(res, ensure_ascii=False, indent=1))
    tmp.replace(OUT / "cmq.json")
    print(json.dumps({k: v for k, v in res.items() if k != "rows"}, ensure_ascii=False, indent=1))
    _ = demon


# ----------------------------------------------------------------------------- отпускание
def release_series(s, every=1):
    """Ввод 0 скачком с установившейся Vmax с добором; 30 с; ряды + перегрузка (подъёмная полос / вес)."""
    Vt = s.trim_state["V"]
    _, o = V2._pull(s, True)
    if o.get("blowup"):
        return None, o, Vt
    lifts = []
    orig = s.wing_aero

    def wa(pos, vel, R, w):
        F, M, info = orig(pos, vel, R, w)
        wa.last = (F, M)
        return F, M, info
    wa.last = (np.zeros(3), np.zeros(3))
    s.wing_aero = wa
    rec = {"t": [], "V": [], "alpha": [], "theta": [], "q": [], "n": [], "rel_x": [], "fh_x": [], "tension": [],
           "M_aero": [], "h": []}
    n = int(round(30.0 / s.dt))
    blow = False
    for i in range(n):
        s.step(Control())
        ob = s.observe()
        if not np.isfinite(ob["phi"]) or ob["V"] > 80:
            blow = True
            break
        F, M = wa.last
        Fb = s.R.T @ F
        if i % every == 0:
            rec["t"].append(s.t)
            for k in ("V", "alpha", "theta", "q", "rel_x", "fh_x", "tension", "h"):
                rec[k].append(float(ob[k]))
            rec["n"].append(float(np.linalg.norm(F) / (s.p.m_total * G)))
            rec["M_aero"].append(float((s.R.T @ M)[1]))
            lifts.append(-Fb[2])
    s.wing_aero = orig
    r = {k: np.array(v) for k, v in rec.items()}
    if len(r["t"]):
        r["t"] = r["t"] - r["t"][0]
    if blow:
        r["blowup"] = True
    return r, o, Vt


def release_metrics(r, Vt):
    blow = bool(r.get("blowup"))
    th, al = np.degrees(r["theta"]), np.degrees(r["alpha"])
    tail = r["t"] >= 25.0
    v_end = float(r["V"][tail].mean()) if (not blow and tail.any()) else float("nan")
    returned = bool(not blow and math.isfinite(v_end) and abs(v_end - Vt) <= 0.10 * Vt)
    # время возврата: последний выход V из ±10 % трима
    out_band = np.abs(r["V"] - Vt) > 0.10 * Vt
    t_ret = float(r["t"][np.nonzero(out_band)[0][-1]]) if out_band.any() and returned else (0.0 if returned else float("nan"))
    tuck = bool(blow or th.min() < -60.0 or np.abs(al).max() > 90.0 or not returned)
    # до переворота: всё, что раньше первого кадра с тангажом < −60° или |α| > 90° (в кувырке |F|/W полос при
    # q > 1000 °/с теряет смысл перегрузки аппарата — полосы квазистатичны)
    bad = np.nonzero((th < -60.0) | (np.abs(al) > 90.0))[0]
    k = int(bad[0]) if len(bad) else len(th)
    pre = slice(0, max(k, 1))
    return {"rel_theta_min_deg": float(th.min()), "rel_theta_max_deg": float(th.max()),
            "rel_alpha_min_deg": float(al.min()), "rel_alpha_max_deg": float(al.max()),
            "rel_g_max": float(r["n"][pre].max()), "rel_g_max_raw": float(r["n"].max()),
            "rel_theta_max_pre_deg": float(th[pre].max()), "rel_t_tumble_s": float(r["t"][k]) if len(bad) else float("nan"),
            "rel_V_tumble_kmh": float(r["V"][k] * 3.6) if len(bad) else float("nan"), "rel_q_max_dps": float(np.degrees(np.abs(r["q"]).max())),
            "rel_V_end_kmh": v_end * 3.6, "rel_V_max_kmh": float(r["V"].max() * 3.6), "rel_returned": returned,
            "rel_t_return_s": t_ret, "rel_dh_max_m": float(r["h"].max() - r["h"][0]), "tuck": tuck, "blowup": blow}


def sc_release(wing, var):
    s = make(wing, var)
    r, o, Vt = release_series(s)
    out = {f"full_{k}": v for k, v in o.items()}
    if r is None:
        out["tuck"] = True
        return out
    out.update(release_metrics(r, Vt))
    return out


def sc_pull(wing, var):
    s = make(wing, var)
    _, o = V2._pull(s, False)
    return {f"pull_{k}": v for k, v in o.items()}


def sc_trim(wing, var):
    s = make(wing, var)
    st = s.trim_state
    out = {"trim_kmh": st["V"] * 3.6, "alpha_trim_deg": D(st["alpha"]), "Kn": trim.static_margin(s, st["alpha"], st["V"]),
           "sink_ms": st["V"] * math.sin(st["gamma"]), "dcm0": s.p.dcm0}
    out.update(V2.phugoid(make(wing, var)))
    return out


def sc_stall(wing, var):
    s = make(wing, var)
    r = run(s, lambda t, o: Control(pitch=min(t / 15.0, 1.0)), 25.0, every=1)
    t, V, sf = r["t"], r["V"], r["stall_frac"]
    k = int(np.argmax(sf >= 0.3)) if (sf >= 0.3).any() else None
    return {"stall_onset_kmh": float(V[k] * 3.6) if k is not None else float("nan")}


SCEN = {"release": sc_release, "trim": sc_trim, "pull": sc_pull, "stall": sc_stall}
VARS = ("base", "nl", "fix")


def job(a):
    wing, var, sc = a
    t0 = time.time()
    try:
        r, err = SCEN[sc](wing, var), None
    except Exception:
        r, err = {}, traceback.format_exc()
    return {"key": f"{wing}/{var}/{sc}", "wing": wing, "var": var, "sc": sc, "err": err, "sec": round(time.time() - t0, 1), **r}


def cmd_diag(args):
    dd = OUT / "diag"
    dd.mkdir(parents=True, exist_ok=True)
    wings = args.wings.split(",") if args.wings else DIAG_WINGS
    jobs = [(w, v) for w in wings for v in args.var.split(",")]
    with ProcessPoolExecutor(args.jobs) as ex:
        res = list(ex.map(_diag_one, jobs))
    old = json.loads((OUT / "diag.json").read_text()) if (OUT / "diag.json").exists() else {}
    for k, m in res:
        old[k] = m
        print(k, json.dumps(m, ensure_ascii=False, default=float))
    (OUT / "diag.json").write_text(json.dumps(old, ensure_ascii=False, indent=1, default=float))


def _diag_one(a):
    wing, var = a
    s = make(wing, var)
    r, o, Vt = release_series(s)
    np.savez_compressed(OUT / "diag" / f"{wing}_{var}.npz", Vt=Vt, **{k: v for k, v in r.items() if k != "blowup"})
    m = release_metrics(r, Vt)
    m.update({"Vt_kmh": Vt * 3.6, "Vmax_kmh": o["V_kmh"], "n_lanchester": (o["V_kmh"] / (Vt * 3.6)) ** 2})
    # мгновения: когда α впервые доходит до трима, перегрузка и V в этот момент
    a_t = s.trim_state["alpha"]
    k = int(np.argmax(r["alpha"] >= a_t)) if (r["alpha"] >= a_t).any() else -1
    if k >= 0:
        m.update({"t_alpha_trim_s": float(r["t"][k]), "n_at_alpha_trim": float(r["n"][k]), "V_at_alpha_trim_kmh": float(r["V"][k] * 3.6)})
    k = int(np.argmax(r["n"]))
    m.update({"t_g_max_s": float(r["t"][k]), "alpha_at_gmax_deg": float(D(r["alpha"][k])), "V_at_gmax_kmh": float(r["V"][k] * 3.6),
              "alpha_trim_deg": float(D(a_t))})
    return f"{wing}/{var}", m


def lanchester(wing, V0, tau=0.0, T=30.0, dt=1 / 240):
    """Точка с постоянным CL трима (крыло мгновенно или с запаздыванием tau уходит на α трима) и полярой крыла
    + пилот (CD·A): старт с V0 по глиссаде. Это фугоида Ланчестера с сопротивлением — что сделает любой устойчивый
    по тангажу аппарат, если угол атаки вернётся к триму, а скорость ещё велика."""
    s = make(wing, "nl")
    p = s.p
    W = p.m_total * G
    cl_t = s.trim_state["cl_total"]
    cl0 = 2 * W / (p.rho * p.area * V0 * V0)

    def cd(cl):
        return float(p.polar.cd_at(min(cl, p.polar.cl_max)))
    V, gam, cl = V0, -math.atan(cd(cl0) / cl0), cl0
    gmax, nmax, h, hmax = gam, 0.0, 0.0, 0.0
    for _ in range(int(T / dt)):
        cl = cl_t if tau <= 0 else cl + (cl_t - cl) * dt / tau
        q = 0.5 * p.rho * V * V
        L, Dr = q * p.area * cl, q * p.area * cd(cl)
        V += dt * (-Dr / p.m_total - G * math.sin(gam))
        gam += dt * (L / p.m_total - G * math.cos(gam)) / max(V, 0.5)
        h += dt * V * math.sin(gam)
        gmax, nmax, hmax = max(gmax, gam), max(nmax, L / W), max(hmax, h)
        if V < 1.0:
            break
    return {"V0_kmh": V0 * 3.6, "Vt_kmh": s.trim_state["V"] * 3.6, "tau_s": tau, "gamma_max_deg": D(gmax),
            "n_max": nmax, "dh_max_m": hmax, "loop": bool(gmax > math.pi / 2), "V_min_kmh": V * 3.6}


def cmd_lanchester(args):
    acc = collect() if (OUT / "results.jsonl").exists() else {}
    res = []
    for w in (args.wings.split(",") if args.wings else DIAG_WINGS):
        d = json.loads((OUT / "diag.json").read_text()).get(f"{w}/nl", {})
        V0 = (acc.get(w, {}).get("nl", {}).get("full_V_kmh") or d.get("Vmax_kmh")) / 3.6
        for tau in (0.0, 0.3, 1.0):
            r = lanchester(w, V0, tau)
            r["wing"] = w
            res.append(r)
            print(json.dumps(r, ensure_ascii=False, default=float))
    (OUT / "lanchester.json").write_text(json.dumps(res, ensure_ascii=False, indent=1, default=float))


def cmd_run(args):
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / "results.jsonl"
    done = V2._done(out)
    vars_ = args.vars.split(",")
    jobs = [(w, v, sc) for w in WINGS for v in vars_ for sc in SCEN]
    jobs = [j for j in jobs if "/".join(j) not in done and (not args.only or args.only in "/".join(j))]
    jobs.sort(key=lambda j: {"release": 0, "trim": 1, "pull": 2, "stall": 3}[j[2]])
    print(f"план: {len(jobs)} (сделано {len(done)})", flush=True)
    V2._pool(jobs, out, args.jobs) if False else _pool(jobs, out, args.jobs)


def _pool(jobs, out, n):
    from concurrent.futures import as_completed
    with ProcessPoolExecutor(n) as ex, out.open("a") as f:
        futs = [ex.submit(job, a) for a in jobs]
        for i, fu in enumerate(as_completed(futs)):
            r = fu.result()
            f.write(json.dumps(r, ensure_ascii=False, default=float) + "\n")
            f.flush()
            if r["err"] or i % 10 == 0:
                print(i, r["key"], r["sec"], "ERR" if r["err"] else "ok", flush=True)
                if r["err"]:
                    print(r["err"].splitlines()[-1], flush=True)


# ----------------------------------------------------------------------------- сводка
def collect():
    acc = {}
    for ln in (OUT / "results.jsonl").read_text().splitlines():
        if not ln.strip():
            continue
        r = json.loads(ln)
        if r.get("err"):
            continue
        acc.setdefault(r["wing"], {}).setdefault(r["var"], {}).update(
            {k: v for k, v in r.items() if k not in ("key", "wing", "var", "sc", "err", "sec")})
    return acc


def _med(xs):
    xs = [x for x in xs if x is not None and math.isfinite(x)]
    return float(np.median(xs)) if xs else float("nan")


def cmd_report(args):
    acc = collect()
    pp = V2.passport()
    cq = json.loads((OUT / "cmq.json").read_text())
    wings = [w for w in WINGS if w in acc and all(v in acc[w] for v in VARS)]
    ref_trim = {w: E.wing_cfg(w)["trim_speed_kmh"] for w in wings}
    B = {w: acc[w]["base"] for w in wings}
    N = {w: acc[w]["nl"] for w in wings}
    F = {w: acc[w]["fix"] for w in wings}
    q = V2._ratios({w: F[w].get("full_V_kmh") for w in wings}, pp)
    qn = V2._ratios({w: F[w].get("pull_V_kmh") for w in wings}, pp)
    qb = V2._ratios({w: B[w].get("pull_V_kmh") for w in wings}, pp)
    q_nl = V2._ratios({w: N[w].get("full_V_kmh") for w in wings}, pp)

    def fin(xs):
        return [x for x in xs if x is not None and math.isfinite(x)]
    s = {
        "contract": "VM-К4 v2", "task": "VM-3", "wings": len(wings),
        "vmax_ratio_median": round(float(np.median(q)), 4), "vmax_ratio_p10": round(float(np.percentile(q, 10)), 4),
        "vmax_ratio_median_base": round(float(np.median(qb)), 4), "vmax_ratio_median_normal": round(float(np.median(qn)), 4),
        "vmax_ratio_median_vm2": round(float(np.median(q_nl)), 4), "vmax_ratio_n": len(q),
        "trim_dev_max_kmh": float(max(abs(F[w]["trim_kmh"] - ref_trim[w]) for w in wings)),
        "kn_trim_min": float(min(F[w]["Kn"] for w in wings)),
        "phugoid_unstable_count": int(sum(bool(F[w]["phug_unstable"]) for w in wings)),
        "phugoid_unstable_count_base": int(sum(bool(B[w]["phug_unstable"]) for w in wings)),
        "bar_force_vmax_max_n": float(max(abs(F[w]["full_fx_N"]) for w in wings)),
        "arms_force_max_n": ARMS_FORCE_MAX, "pull_full_m": PULL_FULL, "pull_normal_m": PULL_NORMAL,
        "stall_dev_max_kmh": float(max(abs(F[w]["stall_onset_kmh"] - B[w]["stall_onset_kmh"]) for w in wings)),
        "tuck_count": int(sum(bool(F[w].get("tuck")) for w in wings)),
        "tuck_count_vm2": int(sum(bool(N[w].get("tuck")) for w in wings)),
        "tuck_count_base": int(sum(bool(B[w].get("tuck")) for w in wings)),
        "release_g_max": float(max(fin([F[w].get("rel_g_max") for w in wings]))),
        "release_pitch_max_deg": float(max(fin([F[w].get("rel_theta_max_deg") for w in wings]))),
        "release_g_max_vm2": float(max(fin([N[w].get("rel_g_max") for w in wings]))),
        "release_g_max_base": float(max(fin([B[w].get("rel_g_max") for w in wings]))),
        "release_g_max_raw": float(max(fin([F[w].get("rel_g_max_raw") for w in wings]))),
        "release_g_median": _med([F[w].get("rel_g_max") for w in wings]),
        "cm_q_add": cq["cm_q_add"], "cmq_lit": cq["cmq_lit"], "cmq_wing_median": cq["cmq_wing_median"],
        "cmq_system_median": cq["cmq_system_median"],
        "params": {"NL": V2.NL, "pull_normal_m": PULL_NORMAL, "pull_full_m": PULL_FULL, "arms_force_max_n": ARMS_FORCE_MAX,
                   "cm_q_add": cq["cm_q_add"]},
        "wing_rows": {w: {"base": B[w], "nl": N[w], "fix": F[w], "passport_vmax_kmh": pp.get(w, (None,))[0],
                          "passport_censored": pp.get(w, (None, None))[1], "trim_ref_kmh": ref_trim[w]} for w in wings},
    }
    sens = {}
    for w, d in acc.items():
        for v, r in d.items():
            if v.startswith("q=") and "tuck" in r:
                e = sens.setdefault(v, {"n": 0, "tuck": 0, "g_max": 0.0, "theta_max": -90.0})
                e["n"] += 1
                e["tuck"] += int(bool(r["tuck"]))
                e["g_max"] = max(e["g_max"], r.get("rel_g_max") or 0.0)
                e["theta_max"] = max(e["theta_max"], r.get("rel_theta_max_deg") or -90.0)
    s["sensitivity_cm_q_add"] = sens
    tmp = OUT / "summary.json.tmp"
    tmp.write_text(json.dumps(s, ensure_ascii=False, indent=1, default=float), encoding="utf-8")
    tmp.replace(OUT / "summary.json")
    write_tables(s)
    try:
        write_figs(s)
    except Exception as e:  # графики не входят в приёмку
        print("графики:", e)
    print(json.dumps({k: v for k, v in s.items() if k not in ("wing_rows", "params")}, ensure_ascii=False, indent=1))


def _f(x, fmt="{:.1f}"):
    if isinstance(x, bool):
        return "да" if x else "нет"
    x = V2._num(x)
    return "—" if x is None else fmt.format(x)


def write_tables(s):
    L = ["# VM-3: отпускание штанги с Vmax — таблицы (48 крыльев)\n",
         f"Параметры: {json.dumps(s['params'], ensure_ascii=False)}\n",
         "Варианты: «база» — прежняя модель (ход 0,45 м); «VM-2» — ΔCm(α) + добор 0,7 м; «+Cmq» — VM-2 + pitch.cm_q_add. "
         "Отпускание — ввод 0 скачком с установившейся Vmax с добором (база — с Vmax хода 0,45 м), 30 с. "
         "Переворот — тангаж киля < −60°, |α| > 90° или средняя V за 25–30 с вне ±10 % трима. "
         "n — |сила полос| / полный вес. t возвр. — последний выход V из ±10 % трима.\n"]
    L.append("## Скорости, трим, устойчивость\n")
    L.append("| крыло | трим паспорт | трим +Cmq | Vmax база | Vmax обычный +Cmq | Vmax с добором VM-2 / +Cmq | паспорт VG 0 | "
             "Kn база / +Cmq | фугоида T, с; затух. +Cmq | срыв база / +Cmq |")
    L.append("|" + "---|" * 10)
    for w, r in s["wing_rows"].items():
        b, n, f = r["base"], r["nl"], r["fix"]
        L.append(f"| {w} | {_f(r['trim_ref_kmh'])} | {_f(f['trim_kmh'])} | {_f(b.get('pull_V_kmh'))} | {_f(f.get('pull_V_kmh'))} | "
                 f"{_f(n.get('full_V_kmh'))} / {_f(f.get('full_V_kmh'))} | {_f(r['passport_vmax_kmh'], '{:.0f}')}{' ц' if r['passport_censored'] else ''} | "
                 f"{_f(b['Kn'], '{:.3f}')} / {_f(f['Kn'], '{:.3f}')} | {_f(f['phug_period_s'])}; {_f(f['phug_amp_ratio'], '{:.2f}')} | "
                 f"{_f(b['stall_onset_kmh'])} / {_f(f['stall_onset_kmh'])} |")
    L.append("\n## Отпускание с Vmax\n")
    L.append("| крыло | вариант | V0 | θ мин / макс, ° | α мин / макс, ° | n макс | q макс, °/с | V 25–30 с | t возвр., с | переворот |")
    L.append("|" + "---|" * 10)
    for w, r in s["wing_rows"].items():
        for lab, k in (("база", "base"), ("VM-2", "nl"), ("+Cmq", "fix")):
            x = r[k]
            v0 = x.get("full_V_kmh")
            L.append(f"| {w} | {lab} | {_f(v0)} | {_f(x.get('rel_theta_min_deg'))} / {_f(x.get('rel_theta_max_deg'))} | "
                     f"{_f(x.get('rel_alpha_min_deg'))} / {_f(x.get('rel_alpha_max_deg'))} | {_f(x.get('rel_g_max'), '{:.2f}')} | "
                     f"{_f(x.get('rel_q_max_dps'), '{:.0f}')} | {_f(x.get('rel_V_end_kmh'))} | {_f(x.get('rel_t_return_s'))} | {_f(x.get('tuck'))} |")
    (OUT / "tables.md").write_text("\n".join(L) + "\n", encoding="utf-8")


def write_figs(s):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fd = OUT / "fig"
    fd.mkdir(exist_ok=True)
    dd = OUT / "diag"
    fig, axes = plt.subplots(4, 1, figsize=(9, 10), sharex=True)
    cols = {"base": "#9aa7b8", "nl": "#C44E52", "fix": "#4C72B0"}
    w = "laminar"
    for var in VARS:
        f = dd / f"{w}_{var}.npz"
        if not f.exists():
            continue
        z = np.load(f)
        axes[0].plot(z["t"], z["V"] * 3.6, color=cols[var], label=var)
        axes[1].plot(z["t"], np.degrees(z["alpha"]), color=cols[var])
        axes[2].plot(z["t"], np.degrees(z["theta"]), color=cols[var])
        axes[3].plot(z["t"], z["n"], color=cols[var])
    for ax, lab in zip(axes, ["V, км/ч", "α киля, °", "тангаж киля, °", "n"]):
        ax.set_ylabel(lab)
        ax.grid(alpha=0.3)
    axes[0].legend(fontsize=8)
    axes[0].set_title(f"{w}: отпускание штанги с Vmax")
    axes[-1].set_xlabel("t, с")
    axes[-1].set_xlim(0, 12)
    fig.tight_layout()
    fig.savefig(fd / "release_laminar.png", dpi=130)
    plt.close(fig)
    rows = s["wing_rows"]
    ws = list(rows)
    x = np.arange(len(ws))
    fig, ax = plt.subplots(figsize=(13, 4))
    for i, (var, lab) in enumerate((("base", "база"), ("nl", "VM-2"), ("fix", "+Cmq"))):
        ax.bar(x + (i - 1) * 0.27, [rows[w][var].get("rel_g_max") or 0 for w in ws], 0.27, color=cols[var], label=lab)
    ax.set_xticks(x, ws, rotation=75, fontsize=7)
    ax.set_ylabel("n макс при отпускании")
    ax.legend(fontsize=8)
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(fd / "release_gmax_48.png", dpi=130)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    a = sp.add_parser("cmq"); a.add_argument("--jobs", type=int, default=12)
    a = sp.add_parser("diag"); a.add_argument("--jobs", type=int, default=12); a.add_argument("--wings", default=""); a.add_argument("--var", default="base,nl")
    a = sp.add_parser("run"); a.add_argument("--jobs", type=int, default=12); a.add_argument("--only", default=""); a.add_argument("--vars", default="base,nl,fix")
    sp.add_parser("report")
    a = sp.add_parser("lanchester"); a.add_argument("--wings", default="")
    args = ap.parse_args()
    {"lanchester": cmd_lanchester, "cmq": cmd_cmq, "diag": cmd_diag, "run": cmd_run, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    main()
