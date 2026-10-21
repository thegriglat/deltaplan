#!/usr/bin/env python3
"""TW-16: статика пилота на тросе (2D, продольная), для сверки с PendulumModel.

Крыло — твёрдое тело с массой 34,4 кг: аэродинамика в нейтральной точке (линейная CL(a), параболическая CD,
постоянный момент M0 около НТ — калибруется по триму), вес в ЦМ, реакция стропы в точке подвеса H.
Пилот — точка 85 кг на стропе длиной L=1,2 м, руки дают силу Fb вдоль киля (как PilotArms: f.z=0), реакция на крыло — в ЦМ плюс момент на плече 1,5375 м (pendulum_model.gd:972-974),
сопротивление пилота CdA 0,21 м². Трос: сила T под углом eps вверх по курсу; доля frac_pilot — на пилота,
остальная — на крыло в точке киля на s_fwd впереди подвеса.
Неизвестные: тангаж theta, угол траектории gamma, наклон стропы lam (вперёд от оси «вниз» крыла), натяжение
стропы Fs, сила рук Fb. Заданы: воздушная скорость V, T, eps. Решение — Ньютон, без scipy.
Числа геометрии — configs/wings/sport.json (pendulum), configs/pendulum.json; НТ по высоте z_np — допущение.
"""
import json, sys
import numpy as np

G = 9.80665
RHO = 1.225
S = 14.1
M_W, M_P = 34.4, 85.0
L = 1.2
A_CL, ALPHA0 = 4.5416, np.radians(-6.008)
ALPHA_T = np.radians(11.74)
CDA_P = 0.21
CD0 = 0.03
X_NOSE_CG, X_NOSE_H, X_NOSE_NP = 1.4347, 1.193, 1.3816
Z_CG = -0.0649  # ЦМ ниже киля
Z_NP = 0.0  # допущение: НТ на уровне киля (чувствительность — sens_z_np)
FB_MAX, FB_LIMIT_SHIFT = 300.0, (0.45, 0.70)
W_W, W_P = M_W * G, M_P * G
P = dict(z_np=Z_NP, m0=0.0, k=0.0, nl=False, emp=None)
# дробь кабрирования: CD подбирается по поляре трима (sink 0,899 м/с при 35,4 км/ч)
V_T, SINK_T = 35.4 / 3.6, 0.899


def wing_vec(th):
    return np.array([np.cos(th), np.sin(th)]), np.array([-np.sin(th), np.cos(th)])  # вперёд, вверх (оси крыла)


def off(f, u, th):
    ef, eu = wing_vec(th)
    return f * ef + u * eu


def cross(a, b):
    return a[0] * b[1] - a[1] * b[0]


C_MEAN = 1.35577
NL = dict(soft=0.23298408, luff=1.14591559, a_trim=0.204901654, a_luff=-0.104859382, w=0.0174532925)  # wing_strips.gd:458


def dcm_nl(al):
    """Добавка к Cm(α) сверх линейной НТ-модели: эмпирическая (P['emp'], из свободного полёта модели),
    иначе аналитическая pitch_nl (PD-К2 v8, wing_strips.gd:458-465), иначе 0."""
    if P.get("emp") is not None:
        a, c = P["emp"]
        return float(np.interp(al, a, c))
    if not P["nl"]:
        return 0.0
    x1, x2 = NL["a_trim"] - al, NL["a_luff"] - al
    return (-NL["soft"] * 0.5 * (x1 + np.sqrt(x1 * x1 + NL["w"] ** 2))
            + NL["luff"] * 0.5 * (x2 + np.sqrt(x2 * x2 + NL["w"] ** 2)))


def wing_vec(th):
    return np.array([np.cos(th), np.sin(th)]), np.array([-np.sin(th), np.cos(th)])  # вперёд, вверх (оси крыла)


def off(f, u, th):
    ef, eu = wing_vec(th)
    return f * ef + u * eu


def cross(a, b):
    return a[0] * b[1] - a[1] * b[0]


C_MEAN = 1.35577
NL = dict(soft=0.23298408, luff=1.14591559, a_trim=0.204901654, a_luff=-0.104859382, w=0.0174532925)  # wing_strips.gd:458


EMP = None  # (alpha_rad[], dCm[]) — эмпирическая добавка Cm(α) из свободного полёта модели (identify_cm)


def dcm_nl(al):
    if P.get("emp") is not None:
        a, c = P["emp"]
        return float(np.interp(al, a, c))
    """Нелинейная добавка к Cm (PD-К2 v8, wing_strips.gd:458-465)."""
    if not P["nl"]:
        return 0.0
    x1, x2 = NL["a_trim"] - al, NL["a_luff"] - al
    return (-NL["soft"] * 0.5 * (x1 + np.sqrt(x1 * x1 + NL["w"] ** 2))
            + NL["luff"] * 0.5 * (x2 + np.sqrt(x2 * x2 + NL["w"] ** 2)))



def residual(x, V, T, eps, frac_pilot=1.0, s_fwd=0.0, z_rope_wing=0.0, M0=None, k=None, z_np=None):
    th, gam, lam, Fs, Fb = x
    z_np = P["z_np"] if z_np is None else z_np
    M0 = P["m0"] if M0 is None else M0
    k = P["k"] if k is None else k
    al = th - gam
    CL = A_CL * (al - ALPHA0)
    CD = CD0 + k * CL * CL
    q = 0.5 * RHO * V * V
    Lf, Df = q * S * CL, q * S * CD
    Lh = np.array([-np.sin(gam), np.cos(gam)])
    Dh = -np.array([np.cos(gam), np.sin(gam)])
    Fa = Lf * Lh + Df * Dh
    r_np = off(X_NOSE_CG - X_NOSE_NP, Z_NP_(z_np) - Z_CG, th)
    r_h = off(X_NOSE_CG - X_NOSE_H, 0.0 - Z_CG, th)
    ef, eu = wing_vec(th)
    us = L * (np.cos(lam) * (-eu) + np.sin(lam) * ef) / L  # единичный вектор подвеска → пилот
    Td = np.array([np.cos(np.radians(eps)), np.sin(np.radians(eps))])
    Tp, Tw = T * frac_pilot * Td, T * (1.0 - frac_pilot) * Td
    Dp = -q * CDA_P * np.array([np.cos(gam), np.sin(gam)])
    Fpil = np.array([0.0, -W_P]) + Tp + Dp - Fs * us + Fb * ef
    Fw = np.array([0.0, -W_W]) + Fa + Fs * us - Fb * ef + Tw  # реакция рук -Fb·ef: сила в ЦМ + момент на штанге
    r_t = off(X_NOSE_CG - (X_NOSE_H - s_fwd), z_rope_wing - Z_CG, th)
    r_bar = off(0.0, -1.5375, th)  # PendulumModel: момент рук = r_bar.z · (−fb.x), r_bar.z = 1,5375 м вниз от ЦМ
    Mw = M0 + q * S * C_MEAN * dcm_nl(al) + cross(r_np, Fa) + cross(r_h, Fs * us) + cross(r_bar, -Fb * ef) + cross(r_t, Tw)
    return np.array([Fw[0], Fw[1], Mw, Fpil[0], Fpil[1]]), dict(al=al, CL=CL, us=us)


def Z_NP_(z):
    return z


def newton(f, x0, tol=1e-9, it=80):
    x = np.array(x0, float)
    for _ in range(it):
        r = f(x)
        if np.max(np.abs(r)) < tol:
            return x, True
        J = np.zeros((len(r), len(x)))
        for j in range(len(x)):
            d = np.zeros(len(x)); d[j] = 1e-6
            J[:, j] = (f(x + d) - r) / 1e-6
        try:
            dx = np.linalg.solve(J, -r)
        except np.linalg.LinAlgError:
            return x, False
        t = 1.0
        while t > 1e-3 and np.max(np.abs(f(x + t * dx))) > np.max(np.abs(r)):
            t /= 2
        x = x + t * dx
    return x, False


def calibrate(z_np=Z_NP):
    """Трим: T=0, Fb=0; неизвестные gam, V, Fs, M0, lam0 — сверка с V=9,83 м/с, lam0 ≈ −7,3°."""
    P["z_np"] = z_np
    # CD0 фиксирован, k из поляры трима
    sin_g = SINK_T / V_T
    gam0 = -np.arcsin(sin_g)
    q = 0.5 * RHO * V_T ** 2
    CLt = A_CL * (ALPHA_T - ALPHA0)
    D_tot = (W_W + W_P) * sin_g
    cd_w = (D_tot - q * CDA_P) / (q * S)
    P["k"] = (cd_w - CD0) / CLt ** 2

    def f(y):
        gam, V, Fs, M0, lam = y
        x = [ALPHA_T + gam, gam, lam, Fs, 0.0]
        r, _ = residual(x, V, 0.0, 0.0, M0=M0)
        return r
    y, ok = newton(f, [gam0, V_T, 1100.0, 0.0, -0.12])
    P["m0"] = y[3]
    return dict(gam_deg=np.degrees(y[0]), V=y[1], Fs=y[2], M0=y[3], lam0_deg=np.degrees(y[4]), ok=ok, k=P["k"])


def solve(V, T, eps, x0=None, **kw):
    f = lambda x: residual(x, V, T, eps, **kw)[0]
    x, ok = newton(f, x0 if x0 is not None else [ALPHA_T + np.radians(-5.2), np.radians(-5.2), LAM0, 830.0, 0.0])
    th, gam, lam, Fs, Fb = x
    r = dict(V=V, T=T, eps=eps, ok=bool(ok), theta=np.degrees(th), gamma=np.degrees(gam), alpha=np.degrees(th - gam),
             lam=np.degrees(lam), shift=L * (np.sin(lam) - np.sin(LAM0)), Fs=Fs, Fb=Fb)
    return r, x


def track(V, eps, Ts, **kw):
    """Продолжение по V (от трима) и затем по T."""
    x = None
    for v in np.linspace(V_T, V, 12):
        _, x = solve(v, 0.0, eps, x, **kw)
    rows = []
    for T in Ts:
        for t in np.linspace(0, T, 1 + max(1, int(T // 25))) if T > 0 else [0.0]:
            r, x = solve(V, t, eps, x, **kw)
        rows.append(r)
    return rows


def identify_cm(trim_rows):
    """Добавка Cm(α) модели сверх линейной НТ-модели — из свободного полёта (T=0): при заданных V и силе рук
    модели из баланса сил находим θ, γ, λ, Fs, остаток момента крыла = недостающий момент. → (α[], ΔCm[])."""
    P["nl"] = False
    P["emp"] = None
    al_l, cm_l = [], []
    for r in trim_rows:
        V, Fb = r["v"], r["fx"]
        f4 = lambda y: residual([y[0], y[1], y[2], y[3], Fb], V, 0.0, 0.0)[0][[0, 1, 3, 4]]
        y, ok = newton(f4, [0.0, -0.09, 0.0, 830.0])
        res = residual([y[0], y[1], y[2], y[3], Fb], V, 0.0, 0.0)[0]
        q = 0.5 * RHO * V * V
        al_l.append(y[0] - y[1])
        cm_l.append(-res[2] / (q * S * C_MEAN))
    o = np.argsort(al_l)
    return np.array(al_l)[o], np.array(cm_l)[o]


def t_at_shift(V, eps, target, **kw):
    """Натяжение, при котором потребный ход пилота вперёд = target (м), или None (> 900 Н / не сходится)."""
    x = None
    for v in np.linspace(V_T, V, 12):
        _, x = solve(v, 0.0, eps, x, **kw)
    prev = None
    for T in np.arange(0.0, 901.0, 10.0):
        r, x = solve(V, T, eps, x, **kw)
        if not r["ok"]:
            return None, None
        if r["shift"] >= target:
            if prev is None:
                return 0.0, r
            f = (target - prev["shift"]) / (r["shift"] - prev["shift"])
            return prev["T"] + f * (T - prev["T"]), r
        prev = r
    return None, prev


BRIDLES = (("грудь 100/0", 1.0, 0.0), ("50/50 на киль у подвеса", 0.5, 0.0), ("50/50, киль +20 см", 0.5, 0.20),
           ("50/50, киль +40 см", 0.5, 0.40), ("всё на киль у подвеса", 0.0, 0.0))

if __name__ == "__main__":
    trim_rows = [json.loads(l[4:]) for l in open("out/model_trim.txt")]
    out = {}
    cal = calibrate()
    LAM0 = np.radians(cal["lam0_deg"])
    P["emp"] = identify_cm(trim_rows)
    out["calibration"] = cal
    out["emp_cm"] = {"alpha_deg": np.degrees(P["emp"][0]).tolist(), "dcm": P["emp"][1].tolist()}
    tab = []
    for V in (12.0, 14.0, 16.0, 18.0, 20.0):
        for eps in (20.0, 45.0, 60.0):
            for name, fp, sf in BRIDLES:
                row = dict(V=V, eps=eps, bridle=name)
                x = None
                for v in np.linspace(V_T, V, 12):
                    _, x = solve(v, 0.0, eps, x, frac_pilot=fp, s_fwd=sf)
                for T in (0, 300, 590, 700):
                    r, x = solve(V, float(T), eps, x, frac_pilot=fp, s_fwd=sf)
                    row[f"shift_T{T}"] = r["shift"]
                    row[f"Fb_T{T}"] = r["Fb"]
                    row[f"ok_T{T}"] = r["ok"]
                for tag, tgt in (("T_pull", 0.45), ("T_full", 0.70)):
                    t, _ = t_at_shift(V, eps, tgt, frac_pilot=fp, s_fwd=sf)
                    row[tag] = t
                tab.append(row)
    out["table"] = tab
    # чувствительность к высоте НТ (допущение) — перекалибровка + перенос эмпирической Cm
    sens = []
    for z in (-0.3, 0.0, 0.3):
        c2 = calibrate(z)
        LAM0 = np.radians(c2["lam0_deg"])
        P["emp"] = identify_cm(trim_rows)
        r, _ = solve(16.0, 590.0, 20.0)
        sens.append(dict(z_np=z, shift_V16_T590=r["shift"], Fb=r["Fb"], ok=r["ok"]))
    out["sens_z_np"] = sens
    json.dump(out, open("out/statics.json", "w"), indent=1, default=float)
    import csv
    with open("out/statics_table.csv", "w", newline="") as f:
        w = csv.writer(f)
        keys = list(tab[0].keys())
        w.writerow(keys)
        for r in tab:
            w.writerow([("" if r[k] is None else (round(r[k], 3) if isinstance(r[k], float) else r[k])) for k in keys])
    print(json.dumps(sens))
    for r in tab:
        if r["eps"] == 20.0:
            print(r["V"], r["bridle"], "shift@300/590/700", round(r["shift_T300"], 2), round(r["shift_T590"], 2), round(r["shift_T700"], 2),
                  "Fb@590", round(r["Fb_T590"]), "T0.45", r["T_pull"] and round(r["T_pull"]), "T0.70", r["T_full"] and round(r["T_full"]))
