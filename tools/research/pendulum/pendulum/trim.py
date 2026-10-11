"""Балансировка: установившееся планирование руки без усилия; подвеска под паспортный трим."""

from __future__ import annotations

import math

import numpy as np

from .model import E3, R_from_euler, Sim
from .params import G, Params


def _sim(p: Params, **kw) -> Sim:
    return Sim(p, **kw)


def glide_balance(sim: Sim, alpha: float, V0: float):
    """При угле атаки киля alpha найти V и наклон траектории: подъёмная+сопротивление
    крыла и пилота уравновешивают вес. Возвращает (V, gamma, M_H_y, F_resid, state)."""
    p = sim.p
    V, gam = V0, 0.1
    for _ in range(30):
        th = alpha - gam
        R = R_from_euler(0.0, th, 0.0)
        vel = V * np.array([math.cos(gam), 0.0, math.sin(gam)])
        pos = np.zeros(3)
        Fa, Ma, info = sim.wing_aero(pos, vel, R, np.zeros(3))
        Dp = -0.5 * p.rho * p.pilot_cda * V * vel
        F = Fa + Dp + p.m_total * G * E3
        # подъёмная ⊥ скорости, сопротивление ∥: поправить V по нормали, γ по касательной
        u = vel / V
        n = np.array([-math.sin(gam), 0.0, math.cos(gam)])  # «вниз» ⊥ скорости
        Fn = float(F @ n)  # >0 — не хватает подъёмной
        Ft = float(F @ u)  # >0 — разгоняет
        L = float(-(Fa + Dp) @ n)
        D = float(-(Fa + Dp) @ u)
        gam_new = math.atan2(D, L)
        V = min(V * math.sqrt(min(max(1 + Fn / max(L, 1.0), 0.25), 4.0)), 80.0)
        if abs(gam_new - gam) < 1e-7 and abs(Fn) < 1e-3:
            gam = gam_new
            break
        gam = gam_new
    th = alpha - gam
    R = R_from_euler(0.0, th, 0.0)
    vel = V * np.array([math.cos(gam), 0.0, math.sin(gam)])
    pos = np.zeros(3)
    Fa, Ma, info = sim.wing_aero(pos, vel, R, np.zeros(3))
    Dp = -0.5 * p.rho * p.pilot_cda * V * vel
    rH = R @ sim.r_hang_b
    # момент около H: аэродинамика (около ЦМ) + перенос силы аэродинамики и веса крыла
    M_H = Ma + np.cross(-rH, Fa + p.m_wing * G * E3)
    M_H_b = R.T @ M_H
    load = p.m_pilot * G * E3 + Dp  # пилот тянет H этой силой
    d_b = R.T @ (load / np.linalg.norm(load))
    state = {"pos": [0.0, 0.0, -1000.0], "vel": vel.tolist(), "R": R.tolist(),
             "pilot_dir_b": d_b.tolist(), "V": V, "gamma": gam, "alpha": alpha, "theta": th,
             "cl_total": float(-(R.T @ Fa)[2] / (0.5 * p.rho * V * V * p.area))}
    return V, gam, float(M_H_b[1]), state


def alpha_for_cl(p: Params, cl: float) -> float:
    return cl / p.lift_slope + p.alpha0


def trim_cl_passport(p: Params) -> float:
    """CL трима по паспорту при текущей массе (скорость трима ∝ √M, CL от массы не зависит)."""
    v = p.v_trim_ref
    m = p.m_pilot_ref + p.m_wing
    return 2 * m * G / (p.rho * p.area * v * v)


def solve_hang(p: Params, **simkw) -> float:
    """Положение подвески (м от носа), при котором руки без усилия дают паспортный трим (dcm0)."""
    a_t = alpha_for_cl(p, trim_cl_passport(p))
    def mom(x):
        s = _sim(p.with_(x_hang=x), **simkw)
        return glide_balance(s, a_t, p.v_trim_ref)[2]
    lo, hi = 0.3, 3.0
    mlo, mhi = mom(lo), mom(hi)
    if mlo * mhi > 0:
        return float("nan")
    for _ in range(50):
        mid = 0.5 * (lo + hi)
        mm = mom(mid)
        if mm * mlo > 0:
            lo, mlo = mid, mm
        else:
            hi = mid
    return 0.5 * (lo + hi)


def solve_trim(sim: Sim, V0: float | None = None):
    """Угол атаки, при котором момент около H = 0 (руки без усилия). → (alpha, state)."""
    p = sim.p
    V0 = V0 or p.v_trim_ref
    def mom(a):
        return glide_balance(sim, a, V0)[2]
    lo, hi = p.alpha0 + math.radians(3), math.radians(28)
    mlo, mhi = mom(lo), mom(hi)
    if mlo * mhi > 0:
        return float("nan"), None
    for _ in range(50):
        mid = 0.5 * (lo + hi)
        mm = mom(mid)
        if mm * mlo > 0:
            lo, mlo = mid, mm
        else:
            hi = mid
    a = 0.5 * (lo + hi)
    return a, glide_balance(sim, a, V0)[3]


def static_margin(sim: Sim, alpha: float, V: float) -> float:
    """Kn = −dCm_H/dCL около подвески (доля средней хорды), при той же скорости."""
    p = sim.p
    da = math.radians(0.5)
    out = []
    for a in (alpha - da, alpha + da):
        _, _, M, st = glide_balance(sim, a, V)
        q = 0.5 * p.rho * st["V"] ** 2
        out.append((M / (q * p.area * p.chord_mean), st["cl_total"]))
    return -(out[1][0] - out[0][0]) / (out[1][1] - out[0][1])


def solve_dcm0(p: Params, x_hang: float, **simkw) -> float:
    """Добавка Cm0 (момент паруса: камбер против рефлекса), при которой с подвеской x_hang
    руки без усилия дают паспортный трим. Момент линеен по dcm0 — одно деление."""
    a_t = alpha_for_cl(p, trim_cl_passport(p))
    s = _sim(p.with_(x_hang=x_hang, dcm0=0.0), **simkw)
    V, gam, M, st = glide_balance(s, a_t, p.v_trim_ref)
    q = 0.5 * p.rho * st["V"] ** 2
    return -M / (q * p.area * p.chord_mean)


def neutral_point(p: Params, **simkw) -> float:
    """Нейтральная точка (м от носа): подвеска, при которой dCm_H/dCL = 0."""
    a_t = alpha_for_cl(p, trim_cl_passport(p))
    def kn(x):
        s = _sim(p.with_(x_hang=x), **simkw)
        return static_margin(s, a_t, p.v_trim_ref)
    lo, hi = 0.5, 3.0
    klo = kn(lo)
    for _ in range(40):
        mid = 0.5 * (lo + hi)
        k = kn(mid)
        if (k > 0) == (klo > 0):
            lo, klo = mid, k
        else:
            hi = mid
    return 0.5 * (lo + hi)


def polar_sink(p: Params, V: float) -> float:
    """Снижение по поляре игры на скорости V при текущей массе (как FlightModel.steady_glide)."""
    cos_g, ld = 1.0, 1.0
    m = p.m_total
    for _ in range(4):
        cl = 2 * m * G * cos_g / (p.rho * p.area * V * V)
        ld = cl / float(p.polar.cd_at(cl))
        cos_g = math.cos(math.atan(1 / ld))
    return V * math.sin(math.atan(1 / ld))


def calibrate_cd(sim: Sim, alpha: float) -> float:
    """Один множитель сопротивления полос: в прямом полёте на триме снижение = поляра."""
    for _ in range(4):
        V, gam, _, st = glide_balance(sim, alpha, sim.p.v_trim_ref)
        sink = V * math.sin(gam)
        target = polar_sink(sim.p, V)
        dp = 0.5 * sim.p.rho * V ** 2 * sim.p.pilot_cda
        D_tot = sim.p.m_total * G * math.sin(gam)
        D_target = sim.p.m_total * G * target / V
        D_wing = D_tot - dp
        sim.cd_scale *= (D_target - dp) / D_wing
    return sim.cd_scale


def lateral_derivatives(sim: Sim, st: dict) -> dict:
    """Боковые производные крыла (полосы + эквивалентный киль) около ЦМ системы, оси устойчивости:
    Clβ, Cnβ, CYβ (1/рад), Clp, Cnp, Clr, Cnr (на p·b/2V). Пилот — точка: его сопротивление
    в скольжении даёт боковую силу ниже ЦМ (входит). Для критерия спирали и голландского шага."""
    p = sim.p
    R = np.array(st["R"])
    V = st["V"]
    vel0 = np.array(st["vel"])
    pos = np.zeros(3)
    d_b = np.array(st["pilot_dir_b"]) * p.hang_len
    r_p_b = sim.r_hang_b + d_b  # пилот отн. ЦМ крыла, B
    r_sys_b = r_p_b * p.m_pilot / p.m_total  # ЦМ системы отн. ЦМ крыла
    q = 0.5 * p.rho * V * V
    Sb = p.area * p.span

    def moments(dv_b=np.zeros(3), w_b=np.zeros(3)):
        vel = vel0 + R @ dv_b
        w = R @ w_b
        Fa, Ma, _ = sim.wing_aero(pos, vel, R, w)
        Fb, Mb = R.T @ Fa, R.T @ Ma
        # пилот: сопротивление в своей точке
        vp = vel + np.cross(w, R @ r_p_b)
        Dp = -0.5 * p.rho * p.pilot_cda * np.linalg.norm(vp) * vp
        Dpb = R.T @ Dp
        M = Mb + np.cross(-r_sys_b, Fb) + np.cross(r_p_b - r_sys_b, Dpb)
        return Fb + Dpb, M

    F0, M0 = moments()
    db = math.radians(1.0)
    vb = np.array([0.0, V * math.sin(db), 0.0])
    Fb_, Mb_ = moments(dv_b=vb)
    out = {"Cl_beta": (Mb_[0] - M0[0]) / (q * Sb * db), "Cn_beta": (Mb_[2] - M0[2]) / (q * Sb * db),
           "CY_beta": (Fb_[1] - F0[1]) / (q * p.area * db)}
    dr = 0.05  # безразм. p·b/2V
    rate = dr * 2 * V / p.span
    for name, wv in (("p", np.array([rate, 0, 0])), ("r", np.array([0, 0, rate]))):
        Fx, Mx = moments(w_b=wv)
        out[f"Cl_{name}"] = (Mx[0] - M0[0]) / (q * Sb * dr)
        out[f"Cn_{name}"] = (Mx[2] - M0[2]) / (q * Sb * dr)
    out["spiral_E"] = out["Cl_beta"] * out["Cn_r"] - out["Cn_beta"] * out["Cl_r"]
    out["CL"] = st["cl_total"]
    return out
