"""Сценарии замеров прототипа (без подгонки). Каждая функция → dict чисел (+ ряды для графиков)."""

from __future__ import annotations

import math

import numpy as np

from . import air, trim
from .game_ref import GameModel
from .model import Control, Ground, Sim, R_from_euler
from .params import G, Params, load_params

D = math.degrees
RAD = math.radians


def make(wing: str, *, hang: str = "game", yaw_mode: str = "free", n_links: int = 3, substeps: int = 4,
         dt: float = 1 / 120, air_fn=air.calm, ground=None, **over):
    """Крыло с подвеской: hang='game' — точка подвески игры (AF), dcm0 — под паспортный трим;
    'trim0' — подвеска из трима при dcm0 = 0. over — правки Params."""
    p = load_params(wing)
    p = p.with_(**{k: v for k, v in over.items() if hasattr(p, k)})
    if hang == "game":
        xh = p.x_hang_game + float(over.get("hang_shift", 0.0))
        d = trim.solve_dcm0(p.with_(x_hang=p.x_hang_game), p.x_hang_game) if "dcm0" not in over else over["dcm0"]
        p = p.with_(x_hang=xh, dcm0=d)
    else:
        xh = trim.solve_hang(p.with_(dcm0=0.0))
        p = p.with_(x_hang=xh + float(over.get("hang_shift", 0.0)), dcm0=0.0)
    s = Sim(p, n_links=n_links, substeps=substeps, dt=dt, yaw_mode=yaw_mode, air_fn=air.calm, ground=ground)
    a, st = trim.solve_trim(s)
    trim.calibrate_cd(s, a)
    a, st = trim.solve_trim(s)
    s.reset_air(st)
    s.air_fn = air_fn
    s.trim_state = st
    return s


def run(s: Sim, ctrl, T: float, every: int = 6):
    """ctrl(t, obs) → Control. Возвращает dict рядов."""
    rec = {}
    n = int(round(T / s.dt))
    t0 = s.t
    o = s.observe()
    for i in range(n):
        c = ctrl(s.t - t0, o)
        s.step(c)
        o = s.observe()
        if not np.isfinite(o["phi"]) or o["V"] > 80:
            rec.setdefault("blowup", [s.t - t0])
            break
        if i % every == 0:
            for k, v in o.items():
                rec.setdefault(k, []).append(float(v))
            rec.setdefault("u_roll", []).append(c.roll)
            rec.setdefault("u_pitch", []).append(c.pitch)
    out = {k: np.array(v) for k, v in rec.items()}
    if "t" in out:
        out["t"] = out["t"] - t0
    return out


class BankHold:
    """Регулятор пилота-испытателя (только для постановки опыта): ПИД по крену → смещение."""

    def __init__(self, target, kp=3.0, kd=1.2, ki=0.6, pitch=0.0):
        self.target, self.kp, self.kd, self.ki, self.i, self.pitch = target, kp, kd, ki, 0.0, pitch

    def __call__(self, t, o):
        e = self.target - o["phi"]
        self.i = max(-1.0, min(1.0, self.i + self.ki * e / 120))
        u = self.kp * e - self.kd * o["p"] + self.i
        return Control(roll=max(-1.0, min(1.0, u)), pitch=self.pitch)


def settle(s: Sim, T=4.0):
    run(s, lambda t, o: Control(), T)


def first_cross(t, x, thr, below=True):
    idx = np.where(x <= thr)[0] if below else np.where(x >= thr)[0]
    return float(t[idx[0]]) if len(idx) else float("nan")


# ----------------------------------------------------------------------------- сценарии
def sc_trim(wing, **kw):
    s = make(wing, **kw)
    r = run(s, lambda t, o: Control(), 30.0)
    m = r["t"] > 15
    return {"V_kmh": float(r["V"][m].mean() * 3.6), "sink_ms": float(-r["vz"][m].mean()),
            "alpha_deg": float(D(r["alpha"][m].mean())), "theta_deg": float(D(r["theta"][m].mean())),
            "pilot_rel_x": float(r["rel_x"][m].mean()), "pilot_rel_z": float(r["rel_z"][m].mean()),
            "tension_N": float(r["tension"][m].mean()),
            "V_trim_passport_kmh": s.p.v_trim_ref * 3.6, "x_hang": s.p.x_hang, "dcm0": s.p.dcm0,
            "Kn": trim.static_margin(s, s.trim_state["alpha"], s.trim_state["V"]),
            "Ixx": float(s.I_b[0, 0]), "Iyy": float(s.I_b[1, 1]), "Izz": float(s.I_b[2, 2]),
            "cg_n": s.mm.cg_n.tolist()}


def sc_reversal(wing, bank=45.0, **kw):
    """Из установившегося виража bank° вправо — полное смещение влево; время до bank° влево."""
    s = make(wing, **kw)
    bh = BankHold(RAD(bank), kp=6.0, kd=2.5, ki=1.0)
    r0 = run(s, bh, 14.0)
    phi0 = D(r0["phi"][-1])
    r = run(s, lambda t, o: Control(roll=-1.0), 12.0, every=2)
    t = r["t"]
    return {"phi_start": phi0, "t_to_minus": first_cross(t, r["phi"], RAD(-bank)),
            "t_to_zero": first_cross(t, r["phi"], 0.0), "min_phi": float(D(r["phi"].min())),
            "u_hold": float(np.mean(r0["u_roll"][-20:])), "fy_peak": float(np.abs(r["fh_y"]).max()),
            "beta_max": float(D(np.abs(r["beta"]).max())), "phi_t2": float(D(np.interp(2.0, t, r["phi"]))),
            "stall_max": float(r["stall_frac"].max()), "series": {k: r[k] for k in ("t", "phi", "p", "beta", "rel_y", "fh_y", "pilot_roll")}}


def sc_full_shift(wing, T=15.0, **kw):
    s = make(wing, **kw)
    r = run(s, lambda t, o: Control(roll=1.0), T, every=2)
    t = r["t"]
    out = {f"phi_{x}s": float(D(np.interp(x, t, r["phi"]))) for x in (1, 2, 4, 6, 10, 15) if x <= t[-1]}
    out.update({"phi_max": float(D(r["phi"].max())), "t_to_30": first_cross(t, r["phi"], RAD(30), below=False),
                "t_to_60": first_cross(t, r["phi"], RAD(60), below=False), "beta_ss": float(D(r["beta"][-20:].mean())),
                "inverse_min_phi": float(D(r["phi"][t < 1.0].min())), "stall_max": float(r["stall_frac"].max()),
                "series": {k: r[k] for k in ("t", "phi", "p", "r", "beta", "rel_y", "fh_y", "pilot_roll", "V")}})
    return out


def sc_center(wing, hold=2.0, **kw):
    """2 с полного смещения из горизонта, затем в центр: время до |φ| < 3°."""
    s = make(wing, **kw)
    r = run(s, lambda t, o: Control(roll=1.0 if t < hold else 0.0), 25.0, every=2)
    t = r["t"]
    m = t >= hold
    phi_at = float(D(np.interp(hold, t, r["phi"])))
    after = r["phi"][m]
    ta = t[m] - hold
    lvl = np.where(np.abs(after) < RAD(3))[0]
    return {"phi_at_release": phi_at, "phi_peak": float(D(np.abs(after).max())),
            "t_level": float(ta[lvl[0]]) if len(lvl) else float("nan"),
            "phi_10s": float(D(np.interp(10.0, ta, after))), "phi_20s": float(D(np.interp(20.0, ta, after))),
            "series": {k: r[k] for k in ("t", "phi", "beta", "rel_y")}}


def sc_spiral(wing, bank=None, **kw):
    """Крутой вираж (bank° — по умолчанию overbank игры), пилот в центре 6 с, затем полное
    смещение против: растёт ли крен и сколько до 30°."""
    from .params import GAME_REF
    bank = bank or GAME_REF[wing]["overbank_deg"]
    s = make(wing, **kw)
    bh = BankHold(RAD(bank), kp=6.0, kd=2.5, ki=1.0)
    r0 = run(s, bh, 12.0)
    phi0 = D(r0["phi"][-1])
    r1 = run(s, lambda t, o: Control(), 6.0, every=2)
    r2 = run(s, lambda t, o: Control(roll=-1.0), 15.0, every=2)
    return {"phi_start": phi0, "phi_after_center_6s": float(D(r1["phi"][-1])), "phi_max_center": float(D(r1["phi"].max())),
            "V_after_center_kmh": float(r1["V"][-1] * 3.6), "t_exit_to_30": first_cross(r2["t"], r2["phi"], RAD(30)),
            "stall_max": float(max(r1["stall_frac"].max(), r2["stall_frac"].max()))}


def sc_thermal_edge(wing, offset=15.0, w0=3.0, radius=25.0, **kw):
    """Прямой полёт, руки в нейтрали; ядро термика сбоку справа на offset м от линии полёта."""
    s = make(wing, **kw)
    x0 = s.pos[0] + 60.0  # термик впереди на 60 м
    s.air_fn = air.thermal((x0, s.pos[1] + offset), w0, radius)
    r = run(s, lambda t, o: Control(), 14.0, every=2)
    t = r["t"]
    i = np.argmax(np.abs(r["phi"]))
    g = GameModel(wing)
    # игра: та же траектория (прямо, x от времени), разность w на концах (0,8 полуразмаха)
    half = 0.5 * g.b * 0.8
    vt = g.vt
    def dw(tt, phi):
        x = s.trim_state["V"] * tt
        f = air.thermal((60.0, offset), w0, radius)
        pts = np.array([[x, -half * math.cos(phi), 0.0], [x, half * math.cos(phi), 0.0]])
        w = -f(pts)[:, 2]
        return w[0] - w[1]
    tg, phg, _ = g.roll_run(lambda tt, phi, p: 0.0, T=14.0, dw_fn=dw)
    m10 = t <= 10.0
    i10 = np.argmax(np.abs(r["phi"][m10]))
    return {"phi_8s": float(D(np.interp(8.0, t, r["phi"]))), "phi_extreme_10s": float(D(r["phi"][m10][i10])),
            "t_extreme_10s": float(t[m10][i10]), "phi_extreme": float(D(r["phi"][i])), "t_extreme": float(t[i]), "psi_change": float(D(r["psi"][-1] - r["psi"][0])),
            "p_extreme": float(D(r["p"][np.argmax(np.abs(r["p"]))])),
            "game_phi_extreme": float(D(phg[np.argmax(np.abs(phg))])), "game_t_extreme": float(tg[np.argmax(np.abs(phg))]),
            "series": {"t": t, "phi": r["phi"], "game_t": tg[::2], "game_phi": phg[::2]}}


def _head_world(s: Sim):
    """Голова пилота: 0,75 м вперёд по телу и 0,15 м к подвеске от ЦМ (тело ⊥ стропе, по килю)."""
    d = s.xn[-1] - s.hang_world()
    d = d / np.linalg.norm(d)
    fwd = s.R[:, 0] - (s.R[:, 0] @ d) * d
    fwd /= np.linalg.norm(fwd)
    return s.xn[-1] + 0.75 * fwd - 0.15 * d


def sc_turbulence(wing, sigma=1.0, length=40.0, T=90.0, relaxed=False, seed=1, **kw):
    """Болтанка, руки держат нейтраль (или отпущены): раскачка пилота и головы."""
    s = make(wing, **kw)
    s.air_fn = air.turbulence(sigma, length, seed=seed)
    n = int(T / s.dt)
    rec = {k: [] for k in ("t", "phi", "theta", "rel_x", "rel_y", "pilot_roll", "hx", "hy", "hz", "fh_y", "fh_x", "V")}
    hold = BankHold(0.0, kp=1.5, kd=0.8, ki=0.3)  # пилот держит крылья в горизонте (мягко)
    o = s.observe()
    for i in range(n):
        c = Control(arms_relaxed=True) if relaxed else hold(0.0, o)
        s.step(c)
        o = s.observe()
        if not np.isfinite(o["phi"]):
            break
        if i % 2 == 0:
            hw = _head_world(s)
            hb = s.R.T @ (hw - s.hang_world())  # голова в осях крыла (что видит камера)
            for k, v in (("t", o["t"]), ("phi", o["phi"]), ("theta", o["theta"]), ("rel_x", o["rel_x"]),
                         ("rel_y", o["rel_y"]), ("pilot_roll", o["pilot_roll"]), ("hx", hb[0]), ("hy", hb[1]),
                         ("hz", hb[2]), ("fh_y", o["fh_y"]), ("fh_x", o["fh_x"]), ("V", o["V"])):
                rec[k].append(float(v))
    r = {k: np.array(v) for k, v in rec.items()}
    m = r["t"] > 10
    def peak_freq(x, dt):
        x = x - x.mean()
        f = np.fft.rfftfreq(len(x), dt)
        a = np.abs(np.fft.rfft(x * np.hanning(len(x))))
        k = (f > 0.05) & (f < 5)
        return float(f[k][np.argmax(a[k])])
    dts = 2 * s.dt
    rel_roll = r["pilot_roll"] - r["phi"]
    return {"std_phi": float(D(r["phi"][m].std())), "std_theta": float(D(r["theta"][m].std())),
            "std_rel_y_m": float(r["rel_y"][m].std()), "std_rel_x_m": float(r["rel_x"][m].std()),
            "std_pilot_vs_wing_roll_deg": float(D(np.arctan2(r["rel_y"][m], 1.2).std())),
            "head_std_y_m": float(r["hy"][m].std()), "head_std_x_m": float(r["hx"][m].std()), "head_std_z_m": float(r["hz"][m].std()),
            "head_peak_hz_y": peak_freq(r["hy"][m], dts), "head_peak_hz_x": peak_freq(r["hx"][m], dts),
            "phi_peak_hz": peak_freq(r["phi"][m], dts),
            "fh_y_rms": float(np.sqrt((r["fh_y"][m] ** 2).mean())), "fh_x_rms": float(np.sqrt((r["fh_x"][m] ** 2).mean())),
            "max_stretch_m": s.max_stretch, "blowup": bool(len(r["t"]) < n // 2 - 2),
            "series": {k: r[k] for k in ("t", "phi", "rel_y", "hy", "pilot_roll")}}


def sc_pendulum(wing, **kw):
    """Руки отпущены, пилоту — боковой и продольный толчок 0,5 м/с: период и затухание."""
    out = {}
    for axis, key in ((1, "lat"), (0, "lon")):
        s = make(wing, **kw)
        settle(s, 3.0)
        dv = np.zeros(3)
        dv[axis] = 0.5
        s.vn[-1] = s.vn[-1] + s.R @ dv
        r = run(s, lambda t, o: Control(arms_relaxed=True), 20.0, every=1)
        x = r["rel_y" if axis == 1 else "rel_x"]
        x = x - np.median(x[-240:]) if len(x) > 240 else x - x.mean()
        t = r["t"]
        zc = [t[i] for i in range(1, len(x)) if x[i - 1] < 0 <= x[i]]
        pk = [abs(x[i]) for i in range(1, len(x) - 1) if abs(x[i]) >= abs(x[i - 1]) and abs(x[i]) > abs(x[i + 1])]
        per = float(np.median(np.diff(zc))) if len(zc) >= 3 else float("nan")
        dec = float(pk[2] / pk[0]) if len(pk) >= 3 and pk[0] > 0 else float("nan")
        out[f"{key}_period_s"] = per
        out[f"{key}_ratio_per_period"] = dec
        out[f"{key}_amp0_m"] = float(pk[0]) if pk else float("nan")
        out[f"{key}_phi_swing_deg"] = float(D(np.ptp(r["phi"])))
        if key == "lat":
            out["series_lat"] = {"t": t, "x": x, "phi": r["phi"]}
    L = load_params(wing).hang_len
    out["simple_pendulum_s"] = 2 * math.pi * math.sqrt(L / G)
    return out


def sc_phugoid(wing, dv=3.0, **kw):
    s = make(wing, **kw)
    s.vel = s.vel * (1 + dv / np.linalg.norm(s.vel))
    s.vn = s.vn + (s.vel - s.vn[-1])
    r = run(s, lambda t, o: Control(), 60.0, every=2)
    t, V = r["t"], r["V"]
    pk = [i for i in range(1, len(V) - 1) if V[i] > V[i - 1] and V[i] >= V[i + 1]]
    per = float(np.median(np.diff(t[pk]))) if len(pk) >= 2 else float("nan")
    Vm = np.median(V[-300:])
    amps = [V[i] - Vm for i in pk]
    ratio = float(amps[1] / amps[0]) if len(amps) >= 2 and amps[0] != 0 else float("nan")
    g = GameModel(wing)
    out = {"period_s": per, "amp_ratio_per_period": ratio, "V0_kmh": float(V[0] * 3.6), "V_end_kmh": float(V[-1] * 3.6)}
    for gain, key in ((0.0, "game_nodamp"), (None, "game")):
        tt = g.phugoid_run(dv=dv, gain=gain)
        Vg = tt[:, 1]
        pkg = [i for i in range(1, len(Vg) - 1) if Vg[i] > Vg[i - 1] and Vg[i] >= Vg[i + 1]]
        Vgm = Vg[-1]
        out[f"{key}_period_s"] = float(np.median(np.diff(tt[pkg, 0]))) if len(pkg) >= 2 else float("nan")
        ag = [Vg[i] - Vgm for i in pkg]
        out[f"{key}_amp_ratio"] = float(ag[1] / ag[0]) if len(ag) >= 2 and ag[0] != 0 else float("nan")
    out["series"] = {"t": t, "V": V}
    return out


def sc_bar(wing, **kw):
    """Трапеция: полная/половина «на себя», «от себя» — установившаяся скорость и усилие рук."""
    out = {}
    for u in (-1.0, -0.5, 0.5, 1.0):
        s = make(wing, **kw)
        r = run(s, lambda t, o: Control(pitch=u), 25.0)
        m = r["t"] > 15
        out[f"V_kmh_{u:+.1f}"] = float(r["V"][m].mean() * 3.6)
        out[f"sink_{u:+.1f}"] = float(-r["vz"][m].mean())
        out[f"fx_N_{u:+.1f}"] = float(r["fh_x"][m].mean())
        out[f"stall_{u:+.1f}"] = float(r["stall_frac"][m].max())
    w = load_params(wing)
    out["game_full_pull_kmh"] = w.v_pull_ref * 3.6
    out["game_full_push_kmh"] = w.v_push_ref * 3.6
    return out


def sc_hang_sensitivity(wing, dx=0.016, **kw):
    """Статика: трим при сдвиге подвески вперёд на dx (dcm0 прежний) → км/ч на см."""
    p = load_params(wing)
    xh = p.x_hang_game
    d = trim.solve_dcm0(p.with_(x_hang=xh), xh)
    res = {}
    for sh in (-2 * dx, -dx, 0.0, dx, 2 * dx):
        s = Sim(p.with_(x_hang=xh - sh, dcm0=d))  # вперёд = к носу = меньше «от носа»
        a, st = trim.solve_trim(s)
        res[sh] = (st["V"] * 3.6, st["V"] * math.sin(st["gamma"]))
    v0 = res[0.0][0]
    slope = (res[dx][0] - res[-dx][0]) / (2 * dx * 100)
    out = {"V0_kmh": v0, "kmh_per_cm_forward": slope,
           "V_by_shift_cm": {f"{k*100:+.1f}": v[0] for k, v in res.items()},
           "sink_by_shift_cm": {f"{k*100:+.1f}": v[1] for k, v in res.items()},
           "x_np": trim.neutral_point(p.with_(dcm0=d)), "x_hang_game": xh,
           "x_hang_trim_dcm0_0": trim.solve_hang(p.with_(dcm0=0.0)), "dcm0_at_game_hang": d}
    return out


def sc_ground_run(wing, slope_deg=15.0, wind=0.0, **kw):
    """Разбег со склона: пилот держит стойки, бежит; крыло весом на руках → подъёмная сила
    растёт → стропа натягивается → ноги разгружаются → отрыв (ступни над землёй)."""
    p = load_params(wing)
    gnd = Ground(slope_tan=math.tan(RAD(slope_deg)), h0=0.0)
    s = make(wing, ground=gnd, **kw)
    s.air_fn = air.uniform([-wind, 0.0, 0.0])
    # постановка: пилот стоит (ЦМ на 1 м над землёй), крыло в руках, киль на тангаже старта
    la = 14.0
    p.extra["launch_theta_deg"] = la
    s.p.extra["launch_theta_deg"] = la - slope_deg  # тангаж к горизонту: угол атаки к склону
    xp = np.array([0.0, 0.0, -1.0])
    s.xn = np.stack([xp for _ in range(s.n_links)])
    s.vn = np.zeros((s.n_links, 3))
    th = RAD(la - slope_deg)
    s.R = R_from_euler(0.0, th, 0.0)
    grip_w = s.R @ s.r_grip_b
    shoulder = xp + np.array([0.35, 0.0, -0.45])
    s.pos = shoulder - grip_w
    s.vel = np.zeros(3)
    s.w = np.zeros(3)
    H = s.hang_world()
    for i in range(s.n_links):  # провисшая цепь: узлы между H и пилотом
        s.xn[i] = H + (xp - H) * (i + 1) / s.n_links
    rec = {k: [] for k in ("t", "x", "vx", "feet", "tension", "lift", "hand_z", "h_feet", "theta", "alpha", "V")}
    liftoff = None
    n = int(25.0 / s.dt)
    hands = "uprights"
    for i in range(n):
        tt = i * s.dt
        run_ = tt > 1.0
        if liftoff is not None and tt - liftoff > 1.0:
            hands = "bar"
            if s.neutral_rel is None or getattr(s, "_bar_set", False) is False:
                s.neutral_rel = s.pilot_rel_b()
                s._bar_set = True
        s.step(Control(run=run_, hands=hands))
        o = s.observe()
        hf = -o["hp"] + 0.0
        h_feet = o["hp"] - 1.0 - gnd.height(o["xp"], o["yp"])
        if liftoff is None and h_feet > 0.05 and o["feet"] == 0.0 and tt > 1.5:
            liftoff = tt
        if i % 6 == 0:
            info = s._last_info
            rec["t"].append(tt); rec["x"].append(o["xp"]); rec["vx"].append(o["vxp"]); rec["feet"].append(o["feet"])
            rec["tension"].append(o["tension"]); rec["lift"].append(info["lift"]); rec["hand_z"].append(0.0)
            rec["h_feet"].append(h_feet); rec["theta"].append(o["theta"]); rec["alpha"].append(o["alpha"]); rec["V"].append(o["V"])
        if liftoff is not None and tt - liftoff > 8:
            break
    r = {k: np.array(v) for k, v in rec.items()}
    W = p.m_total * G
    i_t = np.where(r["tension"] > 0.5 * p.m_pilot * G)[0]
    out = {"t_liftoff": liftoff, "x_liftoff": float(np.interp(liftoff, r["t"], r["x"])) if liftoff else float("nan"),
           "v_liftoff_kmh": float(np.interp(liftoff, r["t"], r["V"]) * 3.6) if liftoff else float("nan"),
           "t_strap_half_load": float(r["t"][i_t[0]]) if len(i_t) else float("nan"),
           "max_h_feet_8s": float(r["h_feet"].max()),
           "series": r}
    return out


def sc_numerics(wing, substeps=4, n_links=3, dt=1 / 120, **kw):
    """Устойчивость/точность: переложение и болтанка при разных подшагах и N."""
    a = sc_reversal(wing, substeps=substeps, n_links=n_links, dt=dt, **kw)
    b = sc_turbulence(wing, substeps=substeps, n_links=n_links, dt=dt, T=40.0, **kw)
    return {"rev_t": a["t_to_minus"], "rev_phi_t2": a["phi_t2"], "turb_std_rel_y": b["std_rel_y_m"],
            "turb_head_std_y": b["head_std_y_m"], "max_stretch_m": b["max_stretch_m"], "blowup": b["blowup"]}


def sc_ochi(wing="laminar", force=30.0, t_on=8.5, **kw):
    """Опыт Takamatsu & Ochi 2022 (Wills Wing Sport 2 155, пилот 72,6 кг, крыло 33,4 кг): пилот
    толкает штангу вбок с усилием ~20–40 Н 8,5 с — крыло кренится на ≈ 30° за ≈ 7 с, установившийся
    вираж ≈ 33°. Здесь: ближайшее крыло (laminar: 14,5 м², 10,3 м), масса пилота 72,6 кг, постоянное
    поперечное усилие force на t_on с. → крен через 7 с и максимум."""
    kw.setdefault("m_pilot", 72.6)
    s = make(wing, **kw)
    settle(s, 2.0)
    r = run(s, lambda t, o: Control(force_y=force if t < t_on else None), 20.0, every=2)
    t = r["t"]
    m = (t > t_on + 3) & (t < t_on + 9)
    return {"phi_7s": float(D(np.interp(7.0, t, r["phi"]))), "phi_max": float(D(r["phi"].max())),
            "phi_after_mean": float(D(r["phi"][m].mean())), "fy_after_mean": float(r["fh_y"][m].mean()),
            "fy_after_absmax": float(np.abs(r["fh_y"][m]).max()),
            "phi_15s": float(D(np.interp(15.0, t, r["phi"]))), "rel_y_max": float(r["rel_y"].max()),
            "beta_max": float(D(np.abs(r["beta"]).max()))}
