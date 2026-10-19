#!/usr/bin/env python3
"""VM-6 (VM-К6 v1): переворот при выходе из разгона — гипотезы о пилоте, руках и подвеске на прототипе, 48 крыльев.

Модель — прототип в состоянии игры после порта (VM-2 pitch_nl σ 0,5, добор 0,7 м, shift_x_pull 0,45, force_max_n 300,
cm_q_add 0) плюс то, чего в прототипе не было, а в игре есть (`game`): pull_full_release 0,5 м/с (VM-К3 v2) и прямая
подача рук против кажущегося веса (pilot_arms.gd, arm_ff_load). Сценарии и критерий переворота — VM-К5:
  normal          — pitch −1 рампой 6 с, 70 с, без добора; release_normal — с него плавный выход (pitch −1 → 0 за 0,5 с);
  full            — то же с добором; release_smooth — с него: добор отпущен, pitch −1 → 0 за 0,5 с, 30 с;
  release_1p8     — установившаяся V = min(1,8·Vтрим, V full) на постоянном pitch с добором, затем pitch 0 скачком, 30 с.
Переворот — тангаж киля < −60° или |α| > 90° за 30 с, или средняя V за 25–30 с вне ±10 % трима.

Варианты (`VARS`): base — прототип VM-3 «nl» как есть; game — + ключи игры; дальше — гипотезы (ключи Params, выключены =
текущая модель), каждая поверх game.

  $PY tools/research/pendulum/vm6_run.py diag --wings laminar,sport --vars game,h_x [--jobs 10]  → out/vm6/diag/*.npz, diag.json
  $PY tools/research/pendulum/vm6_run.py run --jobs 12 [--vars game,h_x] [--only release]        → out/vm6/results.jsonl (продолжает)
  $PY tools/research/pendulum/vm6_run.py report                                                  → summary.json, tables.md, fig/
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
import traceback
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import export_reference as E  # noqa: E402
import vm2_run as V2  # noqa: E402
import vm3_run as V3  # noqa: E402
from pendulum import trim  # noqa: E402
from pendulum.model import Control  # noqa: E402
from pendulum.params import G  # noqa: E402

OUT = HERE / "out" / "vm6"
D, RAD = math.degrees, math.radians
WINGS = V2.WINGS
DIAG_WINGS = ["laminar", "sport", "training", "ww_t2c", "aeros_combat_c"]
T_HAND = 0.5  # с, плавный выход (VM-К5)
T_REL = 30.0

# состояние игры после порта поверх VM-3 «nl» (PD-К2 v8, configs/pendulum.json → arms)
GAME = {"pull_full_release": 0.5, "arm_ff_load": True}

# гипотезы: ключи Params (и n_links/substeps Sim) поверх GAME; обоснование чисел — release-tumble.md, «Гипотезы»
HYP: dict[str, dict] = {
    "base": {},  # прототип VM-3 «nl» (без ключей игры)
    "game": dict(GAME),  # игра после порта
    # игра до порта (PD-К2 v7): линейный тангаж, ход 0,45 без добора, прямая подача по кажущемуся весу
    "preport": {"pitch_nl": False, "pull_full": 0.45, "arm_ff_load": True},
    # подвеска: длина (диапазон «Аппарата» 1,0–1,4 м), звенья, податливость, точка вдоль киля (± 3 см)
    "h_len10": dict(GAME, hang_len=1.0), "h_len14": dict(GAME, hang_len=1.4),
    "h_links1": dict(GAME, n_links=1), "h_links6": dict(GAME, n_links=6),
    "h_stiff": dict(GAME, strap_compliance=1.0e-5), "h_soft": dict(GAME, strap_compliance=8.0e-5),
    "h_hang_fwd": dict(GAME, hang_shift=0.03), "h_hang_aft": dict(GAME, hang_shift=-0.03),
    # пилот: тело PB-1, инерция тела по тангажу вместе с крылом, сопротивление пилота (Kroo 1981: 0,12–0,23 м²)
    "h_body": dict(GAME, pilot_body="body"), "h_body_pitch": dict(GAME, body_pitch_coupled=True),
    "h_cda012": dict(GAME, pilot_cda=0.12), "h_cda023": dict(GAME, pilot_cda=0.23),
    # руки: прямая подача прототипа (m·g/L), руки отпущены на вводе 0, предел силы, время реакции
    "h_ff_off": dict(GAME, arm_ff_load=False), "h_relaxed": dict(GAME, arm_neutral_relaxed=True),
    "h_relaxed_x": dict(GAME, arm_neutral_relaxed_x=True),
    "h_one_sided": dict(GAME, arm_one_sided_x=True),
    # пассивная рука (Mussa-Ivaldi et al. 1985; Tsuji et al. 1995): жёсткость 300 Н/м, вязкость 30 Н·с/м на вводе 0
    "h_passive": dict(GAME, arm_neutral_k=300.0, arm_neutral_b=30.0),
    # игра до порта + правка-кандидат (руки на вводе 0 вдоль киля не держат)
    "preport_fix": {"pitch_nl": False, "pull_full": 0.45, "arm_ff_load": True, "arm_neutral_relaxed_x": True},
    "h_force150": dict(GAME, force_max=150.0), "h_force600": dict(GAME, force_max=600.0),
    "h_tau015": dict(GAME, arm_tau=0.15), "h_tau06": dict(GAME, arm_tau=0.6),
    # трапеция: штанга ниже / выше на 0,15 м (стойки), плечо силы рук по тангажу
    "h_bar_low": dict(GAME, upright_len_add=0.15), "h_bar_high": dict(GAME, upright_len_add=-0.15),
}


def make(wing: str, var: str, dt=1 / 120):
    """Крыло VM-3 «nl» (VM-2 + добор 0,7, force_max 300, cm_q_add 0) + ключи варианта; трим — паспортный
    (dcm0 пересчитывается, как генератор игры, если вариант меняет подвеску или пилота)."""
    over = dict(HYP[var])
    sim_kw = {k: over.pop(k) for k in ("n_links",) if k in over}
    shift = over.pop("hang_shift", 0.0)
    du = over.pop("upright_len_add", 0.0)
    nl = dict(V3.NL, cm_q_add=0.0, **over)
    s = V2.make(wing, "nl", nl=nl, dt=dt)
    if sim_kw or shift or du:
        p = s.p.with_(x_hang=s.p.x_hang + shift, upright_len=s.p.upright_len + du)
        s = _rebuild(s, p, dt, sim_kw)
    p = s.p
    a, st = trim.solve_trim(s)
    if abs(st["V"] - p.v_trim_ref) > 0.02 / 3.6:
        # подвеска/пилот изменили трим: dcm0 под паспортный трим (как генератор tools/flight/pendulum_params.py
        # ставит dcm0 под паспорт), секущие по dcm0 на этой же модели
        d0, f0 = p.dcm0, st["V"] - p.v_trim_ref
        d1 = d0 + (0.005 if f0 > 0 else -0.005)
        for _ in range(12):
            s = _rebuild(s, p.with_(dcm0=d1), dt, sim_kw)
            a, st = trim.solve_trim(s)
            f1 = st["V"] - p.v_trim_ref
            if abs(f1) < 0.01 / 3.6 or abs(f1 - f0) < 1e-9:
                break
            d0, f0, d1 = d1, f1, d1 - f1 * (d1 - d0) / (f1 - f0)
    s.reset_air(st)
    s.trim_state = st
    return s


def _rebuild(s, p, dt, sim_kw):
    cd = s.cd_scale
    s2 = E.GameSim(p, yaw_mode="free", dt=dt, substeps=E.substeps_for(dt), **sim_kw)
    s2.cd_scale = cd
    return s2


# ----------------------------------------------------------------------------- прогон с рядами
class Rec:
    """Ряды и метрики выхода: перегрузка — |F полос|/(M·g) (как VM-3/VM-4) и натяжение стропы/вес пилота."""

    KEYS = ("V", "alpha", "theta", "q", "rel_x", "rel_z", "fh_x", "tension", "h")

    def __init__(self, s, every=1):
        self.s, self.every = s, every
        self.d = {k: [] for k in ("t", "n", "M_aero", "M_hand", "cl") + self.KEYS}
        self._orig = s.wing_aero
        self.last = (np.zeros(3), np.zeros(3))
        rec = self

        def wa(pos, vel, R, w):
            F, M, info = rec._orig(pos, vel, R, w)
            rec.last = (F, M)
            return F, M, info
        s.wing_aero = wa

    def push(self, i):
        s = self.s
        if i % self.every:
            return
        ob = s.observe()
        F, M = self.last
        self.d["t"].append(s.t)
        for k in self.KEYS:
            self.d[k].append(float(ob[k]))
        self.d["n"].append(float(np.linalg.norm(F) / (s.p.m_total * G)))
        self.d["M_aero"].append(float((s.R.T @ M)[1]))
        fb = s.hands_force_b
        rb = s.r_bar_b
        self.d["M_hand"].append(float(-(rb[2] * -fb[0])))  # момент рук на крыло по тангажу (оси B, + нос вверх)
        V = max(ob["V"], 0.5)
        self.d["cl"].append(float(-(s.R.T @ F)[2] / (0.5 * s.p.rho * V * V * s.p.area)))

    def close(self):
        self.s.wing_aero = self._orig
        r = {k: np.array(v) for k, v in self.d.items()}
        if len(r["t"]):
            r["t"] = r["t"] - r["t"][0]
        return r


def steady(s, ctrl, T, t_avg):
    """ctrl(t) → Control; среднее V и усилие за t ≥ t_avg; False при развале."""
    n = int(round(T / s.dt))
    vs, fx = [], []
    t0 = s.t
    for _ in range(n):
        s.step(ctrl(s.t - t0))
        ob = s.observe()
        if not np.isfinite(ob["phi"]) or ob["V"] > 80:
            return None
        if s.t - t0 >= t_avg:
            vs.append(ob["V"])
            fx.append(ob["fh_x"])
    return {"V_kmh": float(np.mean(vs) * 3.6), "V_std_kmh": float(np.std(vs) * 3.6), "fx_N": float(np.mean(fx)),
            "rel_x": float(s.observe()["rel_x"])}


def release(s, ctrl, Vt, every=1):
    """30 с выхода: ctrl(t) → Control. → (ряды, метрики VM-К5)."""
    rc = Rec(s, every)
    n = int(round(T_REL / s.dt))
    blow = False
    t0 = s.t
    for i in range(n):
        s.step(ctrl(s.t - t0))
        ob = s.observe()
        if not np.isfinite(ob["phi"]) or ob["V"] > 80:
            blow = True
            break
        rc.push(i)
    r = rc.close()
    if blow:
        r["blowup"] = True
    m = V3.release_metrics(r, Vt) if len(r["t"]) > 10 else {"tuck": True, "blowup": True}
    if len(r["t"]) > 10:
        th = np.degrees(r["theta"])
        bad = np.nonzero((th < -60.0) | (np.abs(np.degrees(r["alpha"])) > 90.0))[0]
        k = int(bad[0]) if len(bad) else len(th)
        pre = slice(0, max(k, 1))
        tw = r["tension"][pre] / (s.p.m_pilot * G)
        m.update({"rel_strap_n_max": float(tw.max()), "rel_strap_n_min": float(tw.min()),
                  "rel_cl_max_pre": float(r["cl"][pre].max()), "rel_cl_trim": float(s.trim_state["cl_total"]),
                  "rel_alpha_max_pre_deg": float(np.degrees(r["alpha"][pre]).max()),
                  "rel_relx_min_pre": float(r["rel_x"][pre].min()), "rel_fhx_max_pre": float(r["fh_x"][pre].max()),
                  "rel_fhx_min_pre": float(r["fh_x"][pre].min())})
    return r, m


def ramp(p_hold, full):
    return lambda t: Control(pitch=p_hold * min(t / 6.0, 1.0), pull_full=full)


def smooth_out(t_hand=T_HAND):
    return lambda t: Control(pitch=-max(1.0 - t / t_hand, 0.0), pull_full=False)


def _hold_hint(wing):
    """pitch удержания 1,8·Vтрим варианта game (если уже посчитан) — первое приближение секущих для гипотез."""
    path = OUT / "results.jsonl"
    if not path.exists():
        return None
    for ln in path.read_text().splitlines():
        if f'"key": "{wing}/game/release"' in ln:
            r = json.loads(ln)
            if not r.get("err"):
                return r["res"].get("release_1p8", {}).get("pitch_hold")
    return None


def hold_speed(wing, var, v_tgt, v_full, Vt):
    """Установившаяся V = v_tgt на постоянном pitch с добором (как pullin_speed.gd → _vm4_steady): секущие по
    прогонам 50 с (среднее за 40–50 с), затем свежая модель — рампа 6 с к найденному pitch, 70 с. → (sim, hold)."""
    def steady_v(pp):
        s = make(wing, var)
        o = steady(s, ramp(pp, True), 50.0, 40.0)
        return float("nan") if o is None else o["V_kmh"] / 3.6
    hint = _hold_hint(wing) if var != "game" else None
    p0 = hint if hint is not None else -min(max((v_tgt ** 2 - Vt ** 2) / max(v_full ** 2 - Vt ** 2, 1.0), 0.05), 1.0)
    f0 = steady_v(p0) - v_tgt
    if abs(f0) < 0.005 * v_tgt:
        s = make(wing, var)
        o = steady(s, ramp(p0, True), 70.0, 60.0)
        return s, (None if o is None else {"V_hold_kmh": o["V_kmh"], "V_hold_std_kmh": o["V_std_kmh"], "pitch_hold": p0,
                                           "secant_iter": 0})
    p1 = min(max(p0 + (0.05 if hint is not None else 0.15) * math.copysign(1.0, f0), -1.0), -0.02)
    f1 = steady_v(p1) - v_tgt
    it = 0
    for _ in range(8):
        it += 1
        if not (math.isfinite(f0) and math.isfinite(f1)) or abs(f1) < 0.005 * v_tgt or abs(f1 - f0) < 1e-6:
            break
        p2 = min(max(p1 - f1 * (p1 - p0) / (f1 - f0), -1.0), -0.02)
        p0, f0, p1 = p1, f1, p2
        f1 = steady_v(p1) - v_tgt
    s = make(wing, var)
    o = steady(s, ramp(p1, True), 70.0, 60.0)
    if o is None:
        return s, None
    return s, {"V_hold_kmh": o["V_kmh"], "V_hold_std_kmh": o["V_std_kmh"], "pitch_hold": p1, "secant_iter": it}


# ----------------------------------------------------------------------------- сценарии
def sc_release(wing, var, keep=False):
    """normal → release_normal; full → release_smooth; 1,8 → release_1p8 (по VM-К5)."""
    out, series = {}, {}
    s = make(wing, var)
    Vt = s.trim_state["V"]
    out["trim_kmh"] = Vt * 3.6
    o = steady(s, ramp(-1.0, False), 70.0, 50.0)
    out["normal"] = o
    if o is None:
        out["release_normal"] = {"tuck": True, "blowup": True}
    else:
        r, m = release(s, smooth_out(), Vt)
        out["release_normal"] = m
        series["release_normal"] = r
    s = make(wing, var)
    o = steady(s, ramp(-1.0, True), 70.0, 50.0)
    out["full"] = o
    if o is None:
        out["release_smooth"] = {"tuck": True, "blowup": True}
        v_full = 1.8 * Vt
    else:
        r, m = release(s, smooth_out(), Vt)
        out["release_smooth"] = m
        series["release_smooth"] = r
        v_full = o["V_kmh"] / 3.6
    v_tgt = min(1.8 * Vt, v_full)
    if v_tgt < v_full - 0.5 / 3.6:
        s, h = hold_speed(wing, var, v_tgt, v_full, Vt)
    else:
        s = make(wing, var)
        h = steady(s, ramp(-1.0, True), 70.0, 50.0)
        h = None if h is None else {"V_hold_kmh": h["V_kmh"], "V_hold_std_kmh": h["V_std_kmh"], "pitch_hold": -1.0}
    if h is None:
        out["release_1p8"] = {"tuck": True, "blowup": True}
    else:
        r, m = release(s, lambda t: Control(), Vt)
        m.update(h)
        m["V_target_kmh"] = v_tgt * 3.6
        out["release_1p8"] = m
        series["release_1p8"] = r
    return (out, series) if keep else out


def sc_trim(wing, var):
    s = make(wing, var)
    st = s.trim_state
    out = {"trim_kmh": st["V"] * 3.6, "alpha_trim_deg": D(st["alpha"]), "Kn": trim.static_margin(s, st["alpha"], st["V"]),
           "dcm0": s.p.dcm0}
    out.update(V2.phugoid(make(wing, var)))
    return out


def sc_stall(wing, var):
    return V3.sc_stall.__wrapped__(wing, var) if hasattr(V3.sc_stall, "__wrapped__") else _stall(wing, var)


def _stall(wing, var):
    from pendulum.scenarios import run
    s = make(wing, var)
    r = run(s, lambda t, o: Control(pitch=min(t / 15.0, 1.0)), 25.0, every=1)
    V, sf = r["V"], r["stall_frac"]
    k = int(np.argmax(sf >= 0.3)) if (sf >= 0.3).any() else None
    return {"stall_onset_kmh": float(V[k] * 3.6) if k is not None else float("nan")}


def sc_turb(wing, var, seeds=20, T=40.0):
    """Болтанка σ 1 м/с (поле эталона PD-8/PD-24: export_reference.turbulence_modes, 24 моды), 20 зёрен по 40 с,
    крен держит BankHold (как sc_turbulence), тангаж 0. Переворот — |крен| > 60°, тангаж < −60° или развал."""
    from pendulum.scenarios import BankHold
    rows = []
    for k in range(seeds):
        s = make(wing, var)
        s.air_fn = E.turbulence_fn(E.turbulence_modes(sigma=1.0, seed=7 + k))
        hold = BankHold(0.0, kp=1.5, kd=0.8, ki=0.3)
        o = s.observe()
        ph, th, blow = 0.0, [0.0, 0.0], False
        for _ in range(int(round(T / s.dt))):
            s.step(hold(0.0, o))
            o = s.observe()
            if not np.isfinite(o["phi"]) or o["V"] > 80:
                blow = True
                break
            ph = max(ph, abs(D(o["phi"])))
            th = [min(th[0], D(o["theta"])), max(th[1], D(o["theta"]))]
        rows.append({"seed": 7 + k, "phi_max_deg": ph, "theta_min_deg": th[0], "theta_max_deg": th[1], "blowup": blow,
                     "upset": bool(blow or ph > 60.0 or th[0] < -60.0)})
    return {"turb_upset": int(sum(r["upset"] for r in rows)), "turb_n": len(rows),
            "turb_phi_max_deg": float(max(r["phi_max_deg"] for r in rows)), "turb_rows": rows}


SCEN = {"release": sc_release, "trim": sc_trim, "stall": _stall, "turb": sc_turb}


def job(a):
    wing, var, sc = a
    t0 = time.time()
    try:
        r, err = SCEN[sc](wing, var), None
    except Exception:
        r, err = {}, traceback.format_exc()
    return {"key": f"{wing}/{var}/{sc}", "wing": wing, "var": var, "sc": sc, "err": err, "sec": round(time.time() - t0, 1),
            "res": r}


def _done(path):
    done = set()
    if path.exists():
        for ln in path.read_text().splitlines():
            if ln.strip():
                r = json.loads(ln)
                if not r.get("err"):
                    done.add(r["key"])
    return done


def cmd_run(args):
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / "results.jsonl"
    done = _done(out)
    wings = args.wings.split(",") if args.wings else WINGS
    scs = args.scen.split(",")
    vs = args.vars.split(",")
    jobs = [(w, v, sc) for v in vs for w in wings for sc in scs]  # по вариантам: game раньше гипотез (подсказка pitch)
    jobs = [j for j in jobs if "/".join(j) not in done]
    print(f"план: {len(jobs)} (сделано {len(done)})", flush=True)
    with ProcessPoolExecutor(args.jobs) as ex, out.open("a") as f:
        futs = [ex.submit(job, a) for a in jobs]
        for i, fu in enumerate(as_completed(futs)):
            r = fu.result()
            f.write(json.dumps(r, ensure_ascii=False, default=float) + "\n")
            f.flush()
            if r["err"] or i % 10 == 0:
                print(i, r["key"], r["sec"], "ERR" if r["err"] else "ok", flush=True)
                if r["err"]:
                    print(r["err"].splitlines()[-1], flush=True)


def lanchester_point(wing, V0, tau=0.0, T=30.0, dt=1 / 240, var="game"):
    """Точка с CL → CL трима (скачком или с запаздыванием tau) и полярой крыла + пилот: старт по глиссаде с V0.
    Тангаж ≈ γ + α трима; критерий — как VM-К5 (θ < −60°, средняя V за 25–30 с вне ±10 %), плюс «свеча»:
    V < 0,5·Vтрим при γ > 30° (точке срыв не грозит, крылу — да, VM-3)."""
    s = make(wing, var)
    p = s.p
    W = p.m_total * G
    st = s.trim_state
    cl_t, a_t, Vt = st["cl_total"], st["alpha"], st["V"]
    cl0 = 2 * W / (p.rho * p.area * V0 * V0)

    def cd(cl):
        return float(p.polar.cd_at(min(cl, p.polar.cl_max)))
    V, gam, cl = V0, -math.atan(cd(cl0) / cl0), cl0
    th_min, g_max, n_max, cand = 0.0, gam, 0.0, False
    vt = []
    for i in range(int(T / dt)):
        t = i * dt
        cl = cl_t if tau <= 0 else cl + (cl_t - cl) * dt / tau
        q = 0.5 * p.rho * V * V
        L, Dr = q * p.area * cl, q * p.area * cd(cl)
        V += dt * (-Dr / p.m_total - G * math.sin(gam))
        gam += dt * (L / p.m_total - G * math.cos(gam)) / max(V, 0.5)
        gam = math.remainder(gam, 2 * math.pi)
        th_min, g_max, n_max = min(th_min, gam + a_t), max(g_max, gam), max(n_max, L / W)
        cand = cand or (V < 0.5 * Vt and gam > RAD(30))
        if t >= 25.0:
            vt.append(V)
        if V < 0.3:
            break
    v_end = float(np.mean(vt)) if vt else float("nan")
    tuck = bool(th_min < RAD(-60) or not (abs(v_end - Vt) <= 0.1 * Vt) or g_max > math.pi / 2)
    return {"V0_kmh": V0 * 3.6, "V0_Vt": V0 / Vt, "tau_s": tau, "gamma_max_deg": D(g_max), "theta_min_deg": D(th_min),
            "n_max": n_max, "candle": cand, "V_end_kmh": v_end * 3.6, "tuck": tuck}


def _lan_job(a):
    wing, ks, taus = a
    s = make(wing, "game")
    Vt = s.trim_state["V"]
    rows = []
    for k in ks:
        for tau in taus:
            r = lanchester_point(wing, k * Vt, tau)
            r["wing"] = wing
            rows.append(r)
    return rows


def cmd_lanchester(args):
    """Точка Ланчестера на 48 крыльях: V0/Vтрим 1,4…2,6, CL скачком и за 0,5 с → out/vm6/lanchester.json."""
    OUT.mkdir(parents=True, exist_ok=True)
    ks = [1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0, 2.2, 2.4, 2.6]
    with ProcessPoolExecutor(args.jobs) as ex:
        rows = [r for rr in ex.map(_lan_job, [(w, ks, (0.0, 0.5)) for w in WINGS]) for r in rr]
    thr = {}
    for tau in (0.0, 0.5):
        for key in ("tuck", "candle"):
            v = []
            for w in WINGS:
                rr = [r for r in rows if r["wing"] == w and r["tau_s"] == tau and r[key]]
                v.append(min(r["V0_Vt"] for r in rr) if rr else float("nan"))
            thr[f"{key}_tau{tau}"] = {"median": float(np.nanmedian(v)), "min": float(np.nanmin(v)), "max": float(np.nanmax(v))}
    res = {"thresholds_V0_Vt": thr, "rows": rows}
    tmp = OUT / "lanchester.json.tmp"
    tmp.write_text(json.dumps(res, ensure_ascii=False, indent=1, default=float))
    tmp.replace(OUT / "lanchester.json")
    print(json.dumps(thr, ensure_ascii=False, indent=1))


def _hand_job(a):
    wing, var, ths = a
    s0 = make(wing, var)
    Vt = s0.trim_state["V"]
    rows = []
    for th in ths:
        s = make(wing, var)
        o = steady(s, ramp(-1.0, True), 70.0, 50.0)
        if o is None:
            rows.append({"wing": wing, "var": var, "t_hand_s": th, "tuck": True, "blowup": True})
            continue
        _, m = release(s, smooth_out(th), Vt)
        rows.append({"wing": wing, "var": var, "t_hand_s": th, "V0_Vt": o["V_kmh"] / 3.6 / Vt, **m})
    return rows


def cmd_handtime(args):
    """Плавный выход с V full за t_hand = 0,5…4 с (справочно для шлюза) → out/vm6/handtime.jsonl."""
    ths = [float(x) for x in args.t.split(",")]
    jobs = [(w, v, ths) for w in (args.wings.split(",") if args.wings else WINGS) for v in args.vars.split(",")]
    with ProcessPoolExecutor(args.jobs) as ex, (OUT / "handtime.jsonl").open("a") as f:
        for rr in ex.map(_hand_job, jobs):
            for r in rr:
                f.write(json.dumps(r, ensure_ascii=False, default=float) + "\n")
                print(r["wing"], r["var"], r["t_hand_s"], r.get("tuck"), round(r.get("rel_theta_max_pre_deg", float("nan")), 1), flush=True)


def _diag_one(a):
    wing, var = a
    t0 = time.time()
    out, series = sc_release(wing, var, keep=True)
    dd = OUT / "diag"
    for k, r in series.items():
        np.savez_compressed(dd / f"{wing}_{var}_{k}.npz", **{kk: v for kk, v in r.items() if kk != "blowup"})
    out["sec"] = round(time.time() - t0, 1)
    return f"{wing}/{var}", out


def cmd_diag(args):
    dd = OUT / "diag"
    dd.mkdir(parents=True, exist_ok=True)
    wings = args.wings.split(",") if args.wings else DIAG_WINGS
    jobs = [(w, v) for w in wings for v in args.vars.split(",")]
    with ProcessPoolExecutor(args.jobs) as ex:
        res = list(ex.map(_diag_one, jobs))
    p = OUT / "diag.json"
    old = json.loads(p.read_text()) if p.exists() else {}
    for k, m in res:
        old[k] = m
        short = {sc: (m[sc].get("tuck"), round(m[sc].get("rel_g_max", float("nan")), 2),
                      round(m[sc].get("rel_theta_max_pre_deg", float("nan")), 1)) for sc in
                 ("release_normal", "release_smooth", "release_1p8") if isinstance(m.get(sc), dict)}
        print(k, m["sec"], "V n/f:", (m.get("normal") or {}).get("V_kmh"), (m.get("full") or {}).get("V_kmh"), short, flush=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(old, ensure_ascii=False, indent=1, default=float))
    tmp.replace(p)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("diag")
    a.add_argument("--wings", default="")
    a.add_argument("--vars", default="game")
    a.add_argument("--jobs", type=int, default=10)
    a = sub.add_parser("run")
    a.add_argument("--wings", default="")
    a.add_argument("--vars", default="base,game")
    a.add_argument("--scen", default="release")
    a.add_argument("--jobs", type=int, default=12)
    a = sub.add_parser("handtime")
    a.add_argument("--wings", default="")
    a.add_argument("--vars", default="game,h_relaxed_x")
    a.add_argument("--t", default="1,2,3,4")
    a.add_argument("--jobs", type=int, default=16)
    a = sub.add_parser("lanchester")
    a.add_argument("--jobs", type=int, default=4)
    sub.add_parser("report")
    args = ap.parse_args()
    {"diag": cmd_diag, "run": cmd_run, "handtime": cmd_handtime, "lanchester": cmd_lanchester, "report": lambda a: cmd_report(a)}[args.cmd](args)


FIX = "h_relaxed_x"  # правка-кандидат (release-tumble.md, «Правка»)
REPRO = ("game", "preport", "base", "preport_fix")
SCS = ("release_normal", "release_smooth", "release_1p8")
# физический смысл гипотезы (release-tumble.md, «Гипотезы»): True — число из антропометрии/руководств/оценки
PHYS = {"h_len10": True, "h_len14": True, "h_links1": True, "h_links6": True, "h_stiff": True, "h_soft": True,
        "h_hang_fwd": True, "h_hang_aft": True, "h_body": True, "h_body_pitch": True, "h_cda012": True, "h_cda023": True,
        "h_ff_off": True, "h_relaxed": True, "h_relaxed_x": True, "h_one_sided": True, "h_passive": True, "h_force150": True, "h_force600": True,
        "h_tau015": True, "h_tau06": True, "h_bar_low": True, "h_bar_high": True}


def collect():
    acc = {}
    for ln in (OUT / "results.jsonl").read_text().splitlines():
        if not ln.strip():
            continue
        r = json.loads(ln)
        if r.get("err"):
            continue
        acc.setdefault(r["var"], {}).setdefault(r["wing"], {}).update(r["res"])
    return acc


def _tuck(res, sc):
    return bool((res.get(sc) or {"tuck": True}).get("tuck", True))


def _fin(xs):
    return [x for x in xs if x is not None and isinstance(x, (int, float)) and math.isfinite(x)]


def cmd_report(args):
    acc = collect()
    pp = V2.passport()
    ref_trim = {w: E.wing_cfg(w)["trim_speed_kmh"] for w in WINGS}
    full48 = lambda v: v in acc and all(w in acc[v] and "release_smooth" in acc[v][w] for w in WINGS)
    G_, F_ = acc["game"], acc[FIX]
    for v in ("game", FIX):
        if not full48(v):
            raise SystemExit(f"нет 48 крыльев у {v}")
    cnt = lambda v, sc, ws=WINGS: int(sum(_tuck(acc[v][w], sc) for w in ws if w in acc[v]))
    hyps = []
    for v in HYP:
        if v in REPRO or v not in acc:
            continue
        ws = [w for w in WINGS if w in acc[v] and "release_smooth" in acc[v][w]]
        ref = {sc: cnt("game", sc, ws) for sc in SCS}
        hyps.append({"name": v, "keys": {k: x for k, x in HYP[v].items() if k not in GAME or GAME[k] != x},
                     "wings": len(ws), "smooth": cnt(v, "release_smooth", ws), "p1_8": cnt(v, "release_1p8", ws),
                     "normal": cnt(v, "release_normal", ws), "game_same_wings": {"smooth": ref["release_smooth"],
                     "p1_8": ref["release_1p8"], "normal": ref["release_normal"]}, "physical": PHYS.get(v, False)})
    q = V2._ratios({w: (F_[w].get("full") or {}).get("V_kmh") for w in WINGS}, pp)
    qg = V2._ratios({w: (G_[w].get("full") or {}).get("V_kmh") for w in WINGS}, pp)
    v0 = {v: {w: {"normal": ((acc[v][w].get("normal") or {}).get("V_kmh", float("nan"))) / acc[v][w]["trim_kmh"],
                  "smooth": ((acc[v][w].get("full") or {}).get("V_kmh", float("nan"))) / acc[v][w]["trim_kmh"],
                  "p1_8": (acc[v][w].get("release_1p8") or {}).get("V_hold_kmh", float("nan")) / acc[v][w]["trim_kmh"]}
              for w in acc[v] if "trim_kmh" in acc[v][w]} for v in acc}
    lan = json.loads((OUT / "lanchester.json").read_text())["thresholds_V0_Vt"] if (OUT / "lanchester.json").exists() else {}
    gs = _fin([(F_[w].get("release_smooth") or {}).get("rel_g_max") for w in WINGS])
    s = {
        "contract": "VM-К6 v1", "task": "VM-6", "wings": len(WINGS), "fix": FIX, "fix_keys": HYP[FIX],
        "repro_smooth": cnt("game", "release_smooth"), "repro_1p8": cnt("game", "release_1p8"),
        "repro_normal": cnt("game", "release_normal"),
        "game_vm4": {"smooth": 40, "p1_8": 29, "normal": 26, "preport_normal": 14},
        "repro_preport_normal": cnt("preport", "release_normal") if full48("preport") else None,
        "repro_base_smooth": cnt("base", "release_smooth") if full48("base") else None,
        "hypotheses": hyps,
        "tuck_smooth_count": cnt(FIX, "release_smooth"), "tuck_1p8_count": cnt(FIX, "release_1p8"),
        "tuck_normal_count": cnt(FIX, "release_normal"),
        "tuck_smooth_wings": [w for w in WINGS if _tuck(F_[w], "release_smooth")],
        "tuck_1p8_wings": [w for w in WINGS if _tuck(F_[w], "release_1p8")],
        "tuck_normal_wings": [w for w in WINGS if _tuck(F_[w], "release_normal")],
        "vmax_ratio_median": round(float(np.median(q)), 4), "vmax_ratio_p10": round(float(np.percentile(q, 10)), 4),
        "vmax_ratio_n": len(q), "vmax_ratio_median_game": round(float(np.median(qg)), 4),
        "trim_dev_max_kmh": float(max(abs(F_[w]["trim_kmh"] - ref_trim[w]) for w in WINGS)),
        "kn_trim_min": float(min(F_[w]["Kn"] for w in WINGS)),
        "phugoid_unstable_count": int(sum(bool(F_[w]["phug_unstable"]) for w in WINGS)),
        "phugoid_unstable_count_base": int(sum(bool(G_[w]["phug_unstable"]) for w in WINGS)),
        "stall_dev_max_kmh": float(max(abs(F_[w]["stall_onset_kmh"] - G_[w]["stall_onset_kmh"]) for w in WINGS
                                       if math.isfinite(F_[w]["stall_onset_kmh"]) and math.isfinite(G_[w]["stall_onset_kmh"]))),
        "release_g_smooth_max": float(max(gs)) if gs else float("nan"),
        "release_g_smooth_max_raw": float(max(_fin([(F_[w].get("release_smooth") or {}).get("rel_g_max_raw") for w in WINGS]))),
        "release_g_smooth_max_game": float(max(_fin([(G_[w].get("release_smooth") or {}).get("rel_g_max") for w in WINGS]))),
        "v0_vt_median": {v: {k: float(np.nanmedian([v0[v][w][k] for w in v0[v]])) for k in ("normal", "smooth", "p1_8")}
                         for v in ("game", FIX, "preport") if v in v0},
        "lanchester_thresholds_V0_Vt": lan,
        "note": "переворот — VM-К5 (тангаж < −60°, |α| > 90° за 30 с, средняя V 25–30 с вне ±10 % трима); "
                "release_g_* — |F полос|/(M·g) до первого кадра переворота; raw — со всем кувырком",
    }
    tmp = OUT / "summary.json.tmp"
    tmp.write_text(json.dumps(s, ensure_ascii=False, indent=1, default=float))
    tmp.replace(OUT / "summary.json")
    _tables(acc, s, v0, pp, ref_trim)
    _figs(acc, v0, lan)
    print(json.dumps({k: v for k, v in s.items() if k not in ("hypotheses",)}, ensure_ascii=False, indent=1, default=float))


def _flags(res):
    return "".join("П" if _tuck(res, sc) else "в" for sc in SCS)


def _tables(acc, s, v0, pp, ref_trim):
    G_, F_ = acc["game"], acc[FIX]
    L = ["# VM-6: переворот при выходе из разгона — таблицы", "",
         "Флаги — release_normal / release_smooth / release_1p8: **П** — переворот, «в» — выход. V0/Vт — скорость перед выходом",
         "к триму. θ — тангаж нос вверх до переворота (макс. по трём выходам), n — |F полос|/(M·g) до переворота в smooth.", "",
         "## Гипотезы", "", "| гипотеза | ключи | крыльев | normal | smooth | 1,8 | game на тех же | физ. |", "|---|---|---|---|---|---|---|---|"]
    for h in s["hypotheses"]:
        g = h["game_same_wings"]
        L.append(f"| {h['name']} | `{json.dumps(h['keys'], ensure_ascii=False)}` | {h['wings']} | {h['normal']} | {h['smooth']} | "
                 f"{h['p1_8']} | {g['normal']} / {g['smooth']} / {g['p1_8']} | {'да' if h['physical'] else 'нет'} |")
    L += ["", "## По крыльям", "", "| крыло | трим (паспорт) | V normal / full, км/ч | V0/Vт normal / full / 1,8 | паспорт VG 0 | "
          "до порта | game | правка | θ game / правка, ° | n smooth game / правка | Kn | фугоида game / правка | срыв game / правка |",
          "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    pre = acc.get("preport", {})
    for w in WINGS:
        g, f = G_[w], F_[w]
        th = lambda r: max(_fin([(r.get(sc) or {}).get("rel_theta_max_pre_deg") for sc in SCS]) or [float("nan")])
        vv = v0["game"][w]
        pv = pp.get(w, (float("nan"), False))
        L.append(f"| {w} | {f['trim_kmh']:.1f} ({ref_trim[w]:.0f}) | {(g.get('normal') or {}).get('V_kmh', float('nan')):.1f} / "
                 f"{(g.get('full') or {}).get('V_kmh', float('nan')):.1f} | {vv['normal']:.2f} / {vv['smooth']:.2f} / {vv['p1_8']:.2f} | "
                 f"{pv[0]:.0f}{' ц' if pv[1] else ''} | {_flags(pre[w])[0] if w in pre else '—'} | {_flags(g)} | {_flags(f)} | "
                 f"{th(g):.0f} / {th(f):.0f} | {(g.get('release_smooth') or {}).get('rel_g_max', float('nan')):.1f} / "
                 f"{(f.get('release_smooth') or {}).get('rel_g_max', float('nan')):.1f} | {f['Kn']:.3f} | "
                 f"{g['phug_amp_ratio']:.2f} / {f['phug_amp_ratio']:.2f} | {g['stall_onset_kmh']:.1f} / {f['stall_onset_kmh']:.1f} |")
    (OUT / "tables.md").write_text("\n".join(L) + "\n")


def _figs(acc, v0, lan):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fd = OUT / "fig"
    fd.mkdir(parents=True, exist_ok=True)
    fig, axs = plt.subplots(1, 2, figsize=(10, 4), sharey=True)
    for ax, v, title in ((axs[0], "game", "игра после порта (game)"), (axs[1], FIX, f"правка ({FIX})")):
        for k, (sc, y) in enumerate((("release_normal", "normal"), ("release_smooth", "smooth"), ("release_1p8", "p1_8"))):
            xs = [v0[v][w][y] for w in WINGS if w in acc[v]]
            tk = [_tuck(acc[v][w], sc) for w in WINGS if w in acc[v]]
            yy = [k + 0.15 * ((i % 5) - 2) / 2 for i in range(len(xs))]
            ax.scatter([x for x, t in zip(xs, tk) if t], [a for a, t in zip(yy, tk) if t], marker="x", c="#b2182b", s=18,
                       label="переворот" if k == 0 else None)
            ax.scatter([x for x, t in zip(xs, tk) if not t], [a for a, t in zip(yy, tk) if not t], marker="o", facecolors="none",
                       edgecolors="#2166ac", s=18, label="выход" if k == 0 else None)
        for key, ls, lab in (("tuck_tau0.5", "--", "точка Ланчестера: θ < −60° / петля"), ("candle_tau0.5", ":", "точка: «свеча» V < 0,5·Vт")):
            if key in lan:
                ax.axvline(lan[key]["median"], ls=ls, c="k", lw=1, label=lab)
        ax.set_yticks([0, 1, 2], ["normal", "smooth", "1,8"])
        ax.set_xlabel("V0 / Vтрим")
        ax.set_title(title)
        ax.grid(alpha=0.3)
    axs[0].legend(fontsize=7, loc="lower right")
    fig.tight_layout()
    fig.savefig(fd / "v0_outcome_48.png", dpi=130)
    plt.close(fig)
    # ряды laminar: 1,8 и smooth, game против правки
    fig, axs = plt.subplots(3, 2, figsize=(10, 7), sharex=True)
    for j, sc in enumerate(("release_1p8", "release_smooth")):
        for v, c in (("game", "#b2182b"), (FIX, "#2166ac")):
            f = OUT / "diag" / f"laminar_{v}_{sc}.npz"
            if not f.exists():
                continue
            r = np.load(f)
            m = r["t"] <= 12
            axs[0, j].plot(r["t"][m], np.degrees(r["theta"][m]), c=c, label=v)
            axs[1, j].plot(r["t"][m], np.degrees(r["alpha"][m]), c=c)
            axs[2, j].plot(r["t"][m], r["rel_x"][m], c=c)
        axs[0, j].set_title(f"laminar, {sc}")
        axs[0, j].axhline(-60, c="k", lw=0.8, ls="--")
        axs[1, j].set_ylim(-20, 60)
        axs[2, j].set_xlabel("t, с")
    axs[0, 0].set_ylabel("тангаж, °")
    axs[1, 0].set_ylabel("α, °")
    axs[2, 0].set_ylabel("пилот вдоль киля, м")
    axs[0, 0].legend(fontsize=8)
    for ax in axs.flat:
        ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(fd / "release_laminar.png", dpi=130)
    plt.close(fig)


if __name__ == "__main__":
    main()
