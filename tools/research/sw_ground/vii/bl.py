"""Интегральный турбулентный слой шероховатой стенки для VII (SWG-10): семейство профилей Coles, импульс Кармана,
вовлечение Хеда, прямой и обратный (полуобратный по Carter) ход, векторно по многим профилям вдоль ветра.

Образец — panels3d/sep.py (march_layer: Хед, _cf2, _equilibrium; не менялся). Отличия (с обоснованием в README):
  * профиль — семейство Coles 1956 для шероховатой стенки, знак u_τ свободный (обратный ток у стенки при a < 0):
        u/U_e = a·(1 + ln η/λ) + (1 − a)·sin²(πη/2),   η = z/δ,  λ = ln(δ/z0),  a = (u_τ/U_e)·λ/κ;
    C_f/2 = sign(a)·(aκ/λ)²; δ*, θ, H, H1 = (δ − δ*)/θ — интегралы этого профиля (аналитически); a = 1 — чистый лог
    (равновесный слой фона bg_log до δ0 = Z_SAT), a = 0 — C_f = 0 (отрыв);
  * переменные состояния — (a, λ), θ и δ* — явные функции, поэтому обращения семейства не нужно;
  * равновесие слоя на ровной земле (атмосферный слой не растёт: трение уравновешено крупномасштабным градиентом
    давления/Кориолисом, рост сверху держит задерживающий слой): постоянные стоки S_m = (C_f0/2)·U_∞² в уравнении
    импульса и S_e = U_∞·F(H1_0) в уравнении вовлечения — допущение, равны трению и вовлечению равновесного слоя;
  * прямой ход: U_e задана; обратный: задана δ* (Carter), U_e — решение. Переключение при H > HTMAX = 2,5
    (XFOIL 6.99, xbl.f MRCHUE: HTMAX = 2.5 — турбулентный предел прямого хода). У семейства dH1/dH = 0 при a ≈ 0,25
    (H ≈ 2,6–2,8): там прямой ход вырожден (аналог сингулярности Голдстейна).
Уравнения (s — длина дуги вдоль поверхности):
    dθ/ds = C_f/2 − (H + 2)(θ/U)dU/ds − S_m/U²                       (Карман)
    d[U(δ − δ*)]/ds = U·F(H1) − S_e,   F = 0,0306 (H1 − 3)^−0,6169    (Head 1958)
"""
from __future__ import annotations

import math

import numpy as np
from scipy.integrate import quad

KAPPA = 0.4
HTMAX = 2.5            # XFOIL 6.99 xbl.f (MRCHUE): предел H турбулентного прямого хода
OMEGA = 0.5            # релаксация Carter: Davis & Carter 1986 (NASA CR, ntrs 19860016816): «underrelaxation 0.5»
LAM_MIN, LAM_MAX = 2.6, 40.0
H_CAP = 10.0          # предел H обратного хода по δ* (дальше — H = const)
DELTA_UP = 4.0        # предел δ/δ0 (защита; узлы на пределе — счётчиком в отчёте)
U_LIM = (0.05, 3.0)    # пределы U_e,visc/U_∞ обратного хода (защита от расходящихся итераций; в ответе не достигаются)
C1 = quad(lambda e: math.log(e) * math.sin(math.pi * e / 2) ** 2, 0.0, 1.0)[0]     # ∫ ln η · sin²(πη/2) dη


def _coef(lam):
    lam = np.asarray(lam, float)
    A = 1 - 2 / lam + 2 / lam ** 2
    B = 0.5 + C1 / lam
    C = 3.0 / 8.0
    return A, B, C


def integrals(a, lam):
    """I1 = ∫f dη, I2 = ∫f² dη и производные по a, λ. → dict."""
    a = np.asarray(a, float)
    lam = np.asarray(lam, float)
    A, B, C = _coef(lam)
    I1 = a * (1 - 1 / lam) + 0.5 * (1 - a)
    I2 = a * a * A + 2 * a * (1 - a) * B + (1 - a) ** 2 * C
    dA = 2 / lam ** 2 - 4 / lam ** 3
    dB = -C1 / lam ** 2
    I1_a = 0.5 - 1 / lam
    I1_l = a / lam ** 2
    I2_a = 2 * a * A + 2 * (1 - 2 * a) * B - 2 * (1 - a) * C
    I2_l = a * a * dA + 2 * a * (1 - a) * dB
    return dict(I1=I1, I2=I2, I1_a=I1_a, I1_l=I1_l, I2_a=I2_a, I2_l=I2_l)


def state(a, lam, z0):
    """(a, λ) → δ, δ*, θ, H, H1, cf2 (= C_f/2 со знаком) и якобиан θ, δ* по (a, λ)."""
    g = integrals(a, lam)
    d = z0 * np.exp(lam)
    D, T = 1 - g["I1"], g["I1"] - g["I2"]
    th, ds = d * T, d * D
    out = dict(delta=d, dstar=ds, theta=th, H=D / T, H1=g["I1"] / T,
               cf2=np.sign(a) * (a * KAPPA / lam) ** 2)
    out["th_a"] = d * (g["I1_a"] - g["I2_a"])
    out["th_l"] = th + d * (g["I1_l"] - g["I2_l"])
    out["ds_a"] = -d * g["I1_a"]
    out["ds_l"] = ds - d * g["I1_l"]
    return out


def a_limits(lam):
    """Допустимый a семейства при λ: снизу — T > 0 с запасом (H ≤ 30), сверху — минимум H по a (дальше H растёт —
    неоднозначно). Численно, векторно по λ."""
    lam = np.atleast_1d(np.asarray(lam, float))
    aa = np.linspace(-0.6, 1.6, 2201)
    g = integrals(aa[None, :], lam[:, None])
    T = g["I1"] - g["I2"]
    H = np.where(T > 0, (1 - g["I1"]) / np.maximum(T, 1e-12), np.inf)
    ihi = np.argmin(np.where(aa[None, :] > 0.5, H, np.inf), 1)
    a_hi = aa[ihi]
    ok = (H <= 30.0) & (aa[None, :] <= a_hi[:, None])
    a_lo = np.array([aa[np.nonzero(r)[0][0]] for r in ok])
    return a_lo, a_hi


def F_head(H1):
    return 0.0306 * np.maximum(np.asarray(H1, float) - 3.0, 1e-6) ** -0.6169


def profile(z, a, lam, z0):
    """u/U_e на высоте z над землёй (z ≥ 0); выше δ — 1; ниже z0 — 0."""
    z = np.asarray(z, float)
    d = z0 * np.exp(lam)
    eta = np.clip(z / d, 1e-12, 1.0)
    f = a * (1 + np.log(eta) / lam) + (1 - a) * np.sin(0.5 * np.pi * eta) ** 2
    f = np.where(z >= d, 1.0, f)
    return np.where(z <= z0, 0.0, f)


class Equilibrium:
    """Равновесный слой фона: δ0 = Z_SAT (bg_log — лог до z_sat), a = 1; стоки S_m, S_e."""

    def __init__(self, z0, delta0, U_inf):
        self.z0, self.delta0, self.U_inf = float(z0), float(delta0), float(U_inf)
        self.lam0 = math.log(delta0 / z0)
        st = state(1.0, self.lam0, z0)
        self.cf2_0 = float(st["cf2"])
        self.H1_0 = float(st["H1"])
        self.H0 = float(st["H"])
        self.theta0, self.dstar0 = float(st["theta"]), float(st["dstar"])
        self.S_m = self.cf2_0 * U_inf ** 2
        self.S_e = U_inf * float(F_head(self.H1_0))


def _rhs(a, lam, U, mode, dU, p_ds, z0, eq):
    """Производные (a', λ', U') из 3×3: Карман, вовлечение, третья строка по режиму:
    mode 0 — прямой (U' = dU), 1 — обратный с заданной δ*' = p_ds, 2 — обратный с H = const."""
    st = state(a, lam, z0)
    th, ds, d, H = st["theta"], st["dstar"], st["delta"], st["H"]
    Uc = np.maximum(U, 1e-3 * eq.U_inf)
    n = np.size(a)
    M = np.zeros((n, 3, 3))
    b = np.zeros((n, 3))
    M[:, 0, 0], M[:, 0, 1], M[:, 0, 2] = st["th_a"], st["th_l"], (H + 2) * th / Uc
    b[:, 0] = st["cf2"] - eq.S_m / Uc ** 2
    M[:, 1, 0] = -Uc * st["ds_a"]
    M[:, 1, 1] = Uc * (d - st["ds_l"])
    M[:, 1, 2] = d - ds
    b[:, 1] = Uc * F_head(st["H1"]) - eq.S_e
    m0, m1, m2 = mode == 0, mode == 1, mode == 2
    M[m0, 2, 2] = 1.0
    b[m0, 2] = dU[m0]
    M[m1, 2, 0], M[m1, 2, 1] = st["ds_a"][m1], st["ds_l"][m1]
    b[m1, 2] = p_ds[m1]
    M[m2, 2, 0] = st["ds_a"][m2] - H[m2] * st["th_a"][m2]
    M[m2, 2, 1] = st["ds_l"][m2] - H[m2] * st["th_l"][m2]
    det = np.linalg.det(M)
    bad = ~np.isfinite(det) | (np.abs(det) < 1e-300)
    M[bad] = np.eye(3)
    b[bad] = 0.0
    x = np.linalg.solve(M, b[..., None])[..., 0]
    return x[:, 0], x[:, 1], x[:, 2], det


def march(s, Ui, dUi, valid, eq, dstar_tgt=None, inv_mask=None, htmax=HTMAX, alim=None):
    """Слой вдоль n_l профилей одновременно. s, Ui, dUi, valid: (n_l, n_s) — длина дуги, U_e невязкая, dU/ds, маска.
    dstar_tgt — δ* предыдущей итерации (обратный ход берёт её наклон dδ*/ds), inv_mask — где обратный ход задан.
    Прямой шаг, давший H > htmax, переделывается обратным (с dstar_tgt, где он задан и конечен, иначе H = const).
    → dict массивов (n_l, n_s): a, lam, theta, dstar, delta, H, cf, U (U_e слоя: невязкая на прямом, вязкая на
    обратном), mode (0 прямой, 1 обратный по δ*, 2 обратный H = const, −1 нет)."""
    nl, ns = Ui.shape
    z0 = eq.z0
    out = {k: np.full((nl, ns), np.nan) for k in ("a", "lam", "theta", "dstar", "delta", "H", "cf", "U")}
    out["mode"] = np.full((nl, ns), -1, int)
    a = np.ones(nl)
    lam = np.full(nl, eq.lam0)
    U = Ui[:, 0].copy()
    started = np.zeros(nl, bool)
    n_fb = 0
    if inv_mask is None:
        inv_mask = np.zeros((nl, ns), bool)
    tgt_ok = np.zeros((nl, ns), bool) if dstar_tgt is None else np.isfinite(dstar_tgt)
    if alim is None:
        lam_tab = np.linspace(LAM_MIN, LAM_MAX, 400)
        lo, hi = a_limits(lam_tab)
        alim = (lam_tab, lo, hi)
    lam_tab, alo_t, ahi_t = alim

    def clamp(a_, l_):
        l_ = np.clip(l_, LAM_MIN, LAM_MAX)
        lo_ = np.interp(l_, lam_tab, alo_t) + 1e-3
        hi_ = np.interp(l_, lam_tab, ahi_t)
        return np.clip(a_, lo_, hi_), l_

    def put(i, sel, mode_v):
        st = state(a[sel], lam[sel], z0)
        out["a"][sel, i], out["lam"][sel, i] = a[sel], lam[sel]
        for k in ("theta", "dstar", "delta", "H"):
            out[k][sel, i] = st[k]
        out["cf"][sel, i] = 2 * st["cf2"]
        out["U"][sel, i] = U[sel]
        out["mode"][sel, i] = mode_v

    for i in range(ns):
        v = valid[:, i]
        new = v & ~started
        if new.any():
            a[new], lam[new], U[new] = 1.0, eq.lam0, Ui[new, i]
            started |= new
            put(i, new, np.zeros(int(new.sum()), int))
        act = v & started & ~new
        if i == 0 or not act.any():
            continue
        idx = np.nonzero(act)[0]
        h = s[idx, i] - s[idx, i - 1]
        a0, l0, U0 = a[idx], lam[idx], U[idx]
        # режим шага
        want_inv = inv_mask[idx, i]
        mode = np.where(want_inv, np.where(tgt_ok[idx, i], 1, 2), 0)

        def step(mode):
            dsn = np.zeros(idx.size)
            if dstar_tgt is not None:
                # заданный наклон δ*(s) предыдущей итерации (форма тела вытеснения; значение — от входа в зону)
                ok2 = tgt_ok[idx, i] & tgt_ok[idx, i - 1]
                dsn = np.where(ok2, (np.nan_to_num(dstar_tgt[idx, i]) - np.nan_to_num(dstar_tgt[idx, i - 1])) / h, 0.0)
            dU0, dU1 = dUi[idx, i - 1], dUi[idx, i]
            k1 = _rhs(a0, l0, np.where(mode == 0, Ui[idx, i - 1], U0), mode, dU0, dsn, z0, eq)
            am, lm = clamp(a0 + 0.5 * h * k1[0], l0 + 0.5 * h * k1[1])
            Um = np.where(mode == 0, 0.5 * (Ui[idx, i - 1] + Ui[idx, i]), U0 + 0.5 * h * k1[2])
            k2 = _rhs(am, lm, Um, mode, 0.5 * (dU0 + dU1), dsn, z0, eq)
            an, ln_ = clamp(a0 + h * k2[0], l0 + h * k2[1])
            Un = np.where(mode == 0, Ui[idx, i], U0 + h * k2[2])
            return an, ln_, Un

        an, ln_, Un = step(mode)
        Hn = state(an, ln_, z0)["H"]
        redo = (mode == 0) & ((Hn > htmax) | (an <= np.interp(ln_, lam_tab, alo_t) + 2e-3))
        if redo.any():
            mode2 = mode.copy()
            mode2[redo] = np.where(tgt_ok[idx[redo], i], 1, 2)
            a2, l2, U2 = step(mode2)
            an, ln_, Un = np.where(redo, a2, an), np.where(redo, l2, ln_), np.where(redo, U2, Un)
            mode = mode2
        # обратный ход по δ*, упёршийся в край семейства (H > H_CAP, δ > DELTA_UP·δ0, U вне U_LIM, не конечно), —
        # повтор шага с H = const (как XFOIL MRCHUE при отказе): защита, узлы считаются (n_fallback)
        stn = state(an, ln_, z0)
        bad = (mode == 1) & (~np.isfinite(an + ln_ + Un) | (stn["H"] > H_CAP) | (ln_ > eq.lam0 + math.log(DELTA_UP))
                             | (Un < U_LIM[0] * eq.U_inf) | (Un > U_LIM[1] * eq.U_inf))
        if bad.any():
            mode3 = mode.copy()
            mode3[bad] = 2
            a3, l3, U3 = step(mode3)
            an, ln_, Un = np.where(bad, a3, an), np.where(bad, l3, ln_), np.where(bad, U3, Un)
            mode = mode3
            n_fb += int(bad.sum())
        ln_ = np.minimum(ln_, eq.lam0 + math.log(DELTA_UP))
        a[idx], lam[idx], U[idx] = an, ln_, np.clip(Un, U_LIM[0] * eq.U_inf, U_LIM[1] * eq.U_inf)
        sel = np.zeros(nl, bool)
        sel[idx] = True
        mm = np.full(nl, -1, int)
        mm[idx] = mode
        put(i, sel, mm[sel])
    out["n_fallback"] = n_fb
    return out
