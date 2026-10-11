"""PD-28: диагностика разбега — журнал сил по времени (прототип GameSim, как sc_ground_run)."""
import math
import sys

import numpy as np

import export_reference as er
from pendulum import air
from pendulum.model import Control, Ground, R_from_euler

RAD = math.radians


def diag(wing, wind=0.0, slope_deg=15.0, pitch_fn=None, every=0.25, T=12.0):
    blk = er.block(wing)
    s = er.make_ground(wing, blk)
    p = s.p
    gnd = Ground(slope_tan=math.tan(RAD(slope_deg)), h0=0.0)
    s.ground = gnd
    a = RAD(slope_deg)
    s.air_fn = air.uniform([-wind * math.cos(a), 0.0, -wind * math.sin(a)])
    la = float(er.wing_cfg(wing)["launch"]["alpha_neutral_deg"])
    xp = np.array([0.0, 0.0, -1.0])
    s.xn = np.stack([xp for _ in range(s.n_links)])
    s.vn = np.zeros((s.n_links, 3))
    s.R = R_from_euler(0.0, RAD(la - slope_deg), 0.0)
    s.pos = xp + np.array([0.35, 0.0, -0.45]) - s.R @ s.r_grip_b
    s.vel = np.zeros(3)
    s.w = np.zeros(3)
    s.neutral_rel = None
    H = s.hang_world()
    for i in range(s.n_links):
        s.xn[i] = H + (xp - H) * (i + 1) / s.n_links
    rec = {}
    legs0 = s._legs

    def legs():
        F = legs0()
        rec["legs"] = F.copy()
        return F
    s._legs = legs
    hands = "uprights"
    liftoff = None
    nxt = 0.0
    print(f"{wing} wind {wind} slope {slope_deg} m_tot {p.m_total:.1f} S {p.area}")
    print(" t    xp    vxp   V    alpha thcmd th   L/W   D_N   CL    T/Wp  feet  Fx_leg Fz_leg hfeet")
    for i in range(int(T / s.dt)):
        tt = i * s.dt
        if liftoff is not None and tt - liftoff > 1.0 and hands == "uprights":
            hands = "bar"
            s.neutral_rel = s.pilot_rel_b()
        va = s.vn[-1] - s.air_fn(s.pos[None])[0]
        d3 = np.array([math.cos(a), 0.0, math.sin(a)])
        u = va + d3 * max(er.MIN_AIRSPEED - float(np.linalg.norm(va)), 0.0)
        u = u / np.linalg.norm(u) if np.linalg.norm(u) > 1e-3 else d3
        pc = pitch_fn(tt) if pitch_fn else 0.0
        p.extra["launch_theta_deg"] = math.degrees(math.asin(max(-1.0, min(1.0, -u[2])))) + la
        s.step(Control(run=tt > 1.0, hands=hands, pitch=pc))
        o = s.observe()
        h_feet = o["hp"] - 1.0 - gnd.height(o["xp"], o["yp"])
        if liftoff is None and h_feet > 0.05 and o["feet"] == 0.0 and tt > 1.5:
            liftoff = tt
            print(f"LIFTOFF t={tt:.2f} x={o['xp']:.1f} V={o['V']*3.6:.1f} kmh")
        if tt >= nxt:
            nxt += every
            Fa, Ma, info = s.wing_aero(s.pos, s.vel, s.R, s.w)
            v_air = s.vel - s.air_fn(s.pos[None])[0]
            V = np.linalg.norm(v_air)
            dhat = v_air / max(V, 1e-6)
            D = -float(Fa @ dhat)
            L = float(np.linalg.norm(Fa + D * dhat))
            q = 0.5 * p.rho * V * V * p.area
            lg = rec.get("legs", np.zeros(3))
            print(f"{tt:4.2f} {o['xp']:5.1f} {o['vxp']:5.2f} {V:4.1f} {math.degrees(o['alpha']):5.1f} "
                  f"{p.extra['launch_theta_deg']:5.1f} {math.degrees(o['theta']):5.1f} "
                  f"{L/(p.m_total*9.81):5.2f} {D:5.0f} {L/max(q,1e-6):5.2f} {o['tension']/(p.m_pilot*9.81):5.2f} "
                  f"{o['feet']:4.2f} {lg[0]:6.0f} {-lg[2]:6.0f} {h_feet:5.2f}")
        if liftoff is not None and tt - liftoff > 2.0:
            break


def liftoff_run(wing, wind=0.0, slope_deg=15.0, push=0.0, push_at=0.3, T=12.0, ti=None):
    """Отрыв: путь (по горизонтали), время бега, V. push — «от себя» после того, как стропа
    взяла push_at веса пилота (пилот чувствует, что крыло тянет вверх)."""
    blk = er.block(wing)
    s = er.make_ground(wing, blk)
    p = s.p
    gnd = Ground(slope_tan=math.tan(RAD(slope_deg)), h0=0.0)
    s.ground = gnd
    a = RAD(slope_deg)
    s.air_fn = air.uniform([-wind * math.cos(a), 0.0, -wind * math.sin(a)])
    la = float(er.wing_cfg(wing)["launch"]["alpha_neutral_deg"])
    if ti is not None:
        p.extra["ground_pitch_ti_s"] = ti
    xp = np.array([0.0, 0.0, -1.0])
    s.xn = np.stack([xp for _ in range(s.n_links)])
    s.vn = np.zeros((s.n_links, 3))
    s.R = R_from_euler(0.0, RAD(la - slope_deg), 0.0)
    s.pos = xp + np.array([0.35, 0.0, -0.45]) - s.R @ s.r_grip_b
    s.vel = np.zeros(3)
    s.w = np.zeros(3)
    H = s.hang_world()
    for i in range(s.n_links):
        s.xn[i] = H + (xp - H) * (i + 1) / s.n_links
    pushing = False
    Wp = p.m_pilot * 9.81
    x_unload = None
    for i in range(int(T / s.dt)):
        tt = i * s.dt
        va = s.vn[-1] - s.air_fn(s.pos[None])[0]
        d3 = np.array([math.cos(a), 0.0, math.sin(a)])
        u = va + d3 * max(er.MIN_AIRSPEED - float(np.linalg.norm(va)), 0.0)
        u = u / np.linalg.norm(u) if np.linalg.norm(u) > 1e-3 else d3
        p.extra["launch_theta_deg"] = math.degrees(math.asin(max(-1.0, min(1.0, -u[2])))) + la
        s.step(Control(run=tt > 1.0, hands="uprights", pitch=push if pushing else 0.0))
        o = s.observe()
        if not pushing and push and o["tension"] > push_at * Wp and tt > 1.5:
            pushing = True
        if x_unload is None and tt > 1.5 and o["feet"] == 0.0:
            x_unload = o["xp"]
        h_feet = o["hp"] - 1.0 - gnd.height(o["xp"], o["yp"])
        if h_feet > 0.05 and o["feet"] == 0.0 and tt > 1.5:
            return dict(x=o["xp"], t=tt - 1.0, v=o["V"] * 3.6, x0=x_unload, alpha=math.degrees(o["alpha"]))
        if h_feet < -0.6:
            return dict(x=float("nan"), t=float("nan"), v=float("nan"), x0=None, alpha=0)
    return dict(x=float("nan"), t=float("nan"), v=float("nan"), x0=x_unload, alpha=0)


def _job(args):
    return args, liftoff_run(*args)


def matrix():
    from multiprocessing import Pool
    ti = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
    jobs = [(w, wind, sl, push, 0.3, 12.0, ti) for w in ("training", "laminar", "sport")
            for sl in (15.0, 20.0) for wind in (0.0, 2.5) for push in (0.0, 0.3)]
    with Pool(8) as pool:
        for (w, wind, sl, push, *_), r in pool.imap(_job, jobs):
            print(f"{w:9s} slope {sl:4.0f} wind {wind:3.1f} push {push:3.1f}: x {r['x']:5.1f} m "
                  f"(ноги без веса {r['x0'] if r['x0'] is None else round(r['x0'],1)}) t {r['t']:4.2f} s V {r['v']:4.1f} км/ч a {r['alpha']:4.1f}")


if __name__ == "__main__":
    wing = sys.argv[1] if len(sys.argv) > 1 else "training"
    wind = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
    if wing == "matrix":
        matrix()
    else:
        diag(wing, wind)
