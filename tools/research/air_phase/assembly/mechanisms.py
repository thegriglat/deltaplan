"""Механизмы фаз для прототипа сборки поля (контракт P8 v1, docs/contracts/air-phase.md; физика —
docs/research/air_phase_experts.md §12, §15). Только numpy/scipy, CPU.

Сетка — как S5 v4: клетки 96×96 по 400 м (оси [j — север, i — восток]), 13 высот над землёй AGL_M. Каждый механизм —
своя функция; формулы, источник и границы применимости — в docstring. Числа — физические (источник рядом) или
численные (помечены). Чего механизм не умеет — в разделе «Границы» docstring и в section.md AP-17.
"""
from __future__ import annotations

import math

import numpy as np
import scipy.fft as sfft
from scipy.linalg import solve_banded
import scipy.sparse as sp
import scipy.sparse.linalg as spla

G = 9.81
THETA0 = 300.0
RHO_CP = 1.2 * 1005.0          # как air3d/air.py (ρ·c_p, Дж/(м³·К))
KAPPA = 0.4
Z0 = 0.1                       # шероховатость решателя (air3d Params.z0), м
F_COR = 1.13e-4                # параметр Кориолиса решателя (Params.f_cor; только для толщины слоя), 1/с
K_FA = 1.0                     # K свободной атмосферы (Params.k_fa), м²/с
ZI_MIN = 300.0                 # Params.zi_min, м
K_SMOOTH_M = 1500.0            # Params.k_smooth_m — сглаживание потока тепла для w*, м
LAM_M, LAM_FRAC = 40.0, 0.0158  # Params.lam, lam_frac — длина перемешивания Блэкадара
HEAT_TAPER_M = 2000.0          # Params.heat_taper_m
SPONGE_SIDE_M = 2000.0         # Params.sponge_side_m — губка у боковых граней (там поле = фон)
TAU_COOL = 7200.0              # Params.tau_cool — выхолаживание θ′ к фону, с
DX = 400.0
X0 = -19200.0
AGL_M = np.array([25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000], np.float64)
# границы ячеек по высоте (посередине между уровнями; как layer_metrics._B)
ZF = np.concatenate([[0.0], 0.5 * (AGL_M[1:] + AGL_M[:-1]), [AGL_M[-1] + 0.5 * (AGL_M[-1] - AGL_M[-2])]])


# ============================================================================ общие помощники
def wind_unit(wdir_from_deg):
    """«Куда дует» (восток, север) по направлению «откуда», ° (как air3d Air: (−sin φ, −cos φ))."""
    a = math.radians(float(wdir_from_deg))
    return np.array([-math.sin(a), -math.cos(a)])


def smoothstep(e0, e1, x):
    t = np.clip((np.asarray(x, np.float64) - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def sigmoid_log(x, x_c, w_dec):
    """Вес фазы σ((lg x − lg x_c)/w) — модель границы P6 `fit_sigmoid` (w — ширина в декадах)."""
    x = np.maximum(np.asarray(x, np.float64), 1e-12)
    return 1.0 / (1.0 + np.exp(-(np.log10(x) - math.log10(x_c)) / w_dec))


def gauss2d(a, sigma):
    """Гауссово сглаживание (σ в клетках), края — отражение (как air3d/air.py gauss2d)."""
    from scipy.ndimage import gaussian_filter
    if sigma <= 0.3:
        return np.asarray(a, np.float64).copy()
    return gaussian_filter(np.asarray(a, np.float64), sigma, mode="reflect", truncate=3.0)


def bg_profile(z, u_sat, alpha, max_profile):
    """Профиль притока решателя (air3d/air.py wind_profile): U(z) = U_sat·min((z/z_sat)^α, 1), z_sat = 10·max_f^(1/α)."""
    z_sat = 10.0 * max_profile ** (1.0 / alpha)
    return u_sat * np.minimum((np.maximum(np.asarray(z, np.float64), Z0) / z_sat) ** alpha, 1.0)


def interp_levels(F, zq, log_below=True):
    """Значение поля F (13, ny, nx) на высоте zq (ny, nx) над землёй: линейно между уровнями AGL_M; ниже 25 м —
    логарифмический закон стенки от первого уровня (log_below, для горизонтальных компонент) или линейно к 0 (w);
    выше 2000 м — верхний уровень."""
    zq = np.asarray(zq, np.float64)
    zc = np.clip(zq, AGL_M[0], AGL_M[-1])
    k = np.clip(np.searchsorted(AGL_M, zc) - 1, 0, len(AGL_M) - 2)
    t = (zc - AGL_M[k]) / (AGL_M[k + 1] - AGL_M[k])
    jj, ii = np.indices(zq.shape)
    out = (1 - t) * F[k, jj, ii] + t * F[k + 1, jj, ii]
    low = zq < AGL_M[0]
    if np.any(low):
        if log_below:
            fac = np.log(np.maximum(zq, 2 * Z0) / Z0) / math.log(AGL_M[0] / Z0)
        else:
            fac = np.clip(zq / AGL_M[0], 0.0, 1.0)
        out = np.where(low, F[0] * fac, out)
    return out


def fetch_m(e, n=96, dx=DX, sponge=SPONGE_SIDE_M):
    """Разгон: расстояние от клетки против ветра (−e) до внутреннего края боковой губки, м (≥ 0). В губке решатель
    держит поле у фона, поэтому пограничный слой притока начинает расти от её края."""
    xc = (np.arange(n) + 0.5) * dx
    L = n * dx
    X, Y = np.meshgrid(xc, xc)
    big = 1e9
    tx = np.where(e[0] > 1e-9, (X - sponge) / max(e[0], 1e-9), np.where(e[0] < -1e-9, (L - sponge - X) / max(-e[0], 1e-9), big))
    ty = np.where(e[1] > 1e-9, (Y - sponge) / max(e[1], 1e-9), np.where(e[1] < -1e-9, (L - sponge - Y) / max(-e[1], 1e-9), big))
    return np.clip(np.minimum(tx, ty), 0.0, 60000.0)


# ============================================================================ фон: толщина слоя и K (как решатель)
def bl_state(hc, heat, z_i_msl, u10, dx=DX):
    """Толщина слоя h, w*, L, u* по столбцам — air3d `Air._bl_depth` (Троен–Март 1986 / Холтслаг–Бовилль 1993):
    u* = κ·U10/ln(10/z0); H сглажен гауссом σ = 1500 м и погашен у края (heat_taper 2000 м, как решатель);
    неустойчиво: h = max(z_i − h_s, 300, 0,3u*/f), w* = (g/θ0·H_k·h)^(1/3); устойчиво: h = min(0,3u*/f, 0,4√(u*L/f)),
    L = −u*³θ0/(κ g H_k). Возвращает dict массивов (ny, nx) и u*."""
    hc = np.asarray(hc, np.float64)
    ny, nx = hc.shape
    H = np.zeros_like(hc) if heat is None else np.asarray(heat, np.float64).copy()
    if np.any(H != 0):
        xe = (np.arange(nx) + 0.5) * dx
        ye = (np.arange(ny) + 0.5) * dx
        exx = np.clip(np.minimum(xe, nx * dx - xe) / HEAT_TAPER_M, 0, 1)
        eyy = np.clip(np.minimum(ye, ny * dx - ye) / HEAT_TAPER_M, 0, 1)
        H = H * (np.sin(0.5 * np.pi * eyy)[:, None] * np.sin(0.5 * np.pi * exx)[None, :]) ** 2
    Hk = H / RHO_CP
    ustar = KAPPA * u10 / math.log(10.0 / Z0) if u10 > 0 else 0.0
    Hs = gauss2d(Hk, K_SMOOTH_M / dx) if np.any(Hk != 0) else np.zeros_like(hc)
    hs = gauss2d(hc, K_SMOOTH_M / dx)
    h_mech = max(0.3 * ustar / F_COR, 1.0)
    unst = Hs > 1e-6
    h_u = np.maximum(np.maximum(z_i_msl - hs, ZI_MIN), h_mech)
    wstar = np.where(unst, (G / THETA0 * np.maximum(Hs, 0) * h_u) ** (1 / 3), 0.0)
    with np.errstate(divide="ignore", invalid="ignore"):
        Lmo = np.where(Hs < -1e-6, -ustar ** 3 * THETA0 / (KAPPA * G * Hs), np.inf)
        h_s = np.where(np.isfinite(Lmo), np.minimum(h_mech, 0.4 * np.sqrt(ustar * np.where(np.isfinite(Lmo), Lmo, 0) / F_COR)), h_mech)
    h = np.maximum(np.where(unst, h_u, h_s), 1.0)
    return dict(h=h, wstar=wstar, L=Lmo, unst=unst, Hk=Hk, Hk_s=Hs, ustar=ustar, h_mech=h_mech)


def _k_profile(z, ustar, wstar, h, L, unst):
    """K_m(z) столба — air3d `Air._closure` (HB93): K = κ·w_m·z·(1 − z/h)² при z < h, не меньше k_fa; w_m: неустойчиво
    (u*³ + 7κ(z_s/h)w*³)^(1/3), z_s = min(z, 0,1h); устойчиво u*/(1 + 5z/L); нейтрально u*."""
    zs = np.minimum(z, 0.1 * h)
    if unst:
        wm = (ustar ** 3 + 7 * KAPPA * (zs / h) * wstar ** 3) ** (1 / 3)
    elif np.isfinite(L):
        wm = ustar / (1 + 5 * z / L)
    else:
        wm = np.full_like(z, ustar)
    kbl = KAPPA * wm * z * np.clip(1 - z / h, 0, 1) ** 2
    return np.maximum(K_FA, np.where(z < h, kbl, 0.0))


def _thomas(a, b, c, d):
    """Прогонка по оси 0 (вектором по остальным осям): a — под, b — диагональ, c — над."""
    n = b.shape[0]
    cp_ = np.empty_like(b)
    dp_ = np.empty_like(d)
    cp_[0] = c[0] / b[0]
    dp_[0] = d[0] / b[0]
    for i in range(1, n):
        m = b[i] - a[i] * cp_[i - 1]
        cp_[i] = c[i] / m
        dp_[i] = (d[i] - a[i] * dp_[i - 1]) / m
    x = np.empty_like(d)
    x[-1] = dp_[-1]
    for i in range(n - 2, -1, -1):
        x[i] = dp_[i] - cp_[i] * x[i + 1]
    return x


def column_bl(u_sat, alpha, max_profile, ustar, wstar, h, L, unst, fetches, dd=250.0, nz=56, ztop=3000.0,
              drag_lambda=0.0, drag_depth=100.0, z_mass=None, cd_form=0.3):
    """Механизм «фон»: рост внутреннего пограничного слоя от края области — одномерный столб того же K-замыкания,
    что у решателя, в лагранжевой постановке t = ∫dx/U_adv:
        ∂u/∂t = ∂/∂z (K ∂u/∂z),  u(z, 0) — профиль притока (степенной до z_sat, выше U_sat),
        K = max(K_HB93, l²|∂u/∂z|), l = κz/(1 + κz/λ), λ = max(40 м, 0,0158h) (Блэкадар; Params.local_k/lam/lam_frac),
        у земли — закон сопротивления τ = (κ/ln(z1/z0))²|u1|u1, наверху u = U_sat.
        сопротивление формы рельефа — распределённый сток импульса F = ½·C_d·(λ_f/h_d)·|u|u в слое z < h_d
        (λ_f — индекс лобовой площади: средний положительный уклон по ветру, h_d = max(2σ_h, 100 м) — толщина слоя
        препятствий; C_d = 0,3 — коэффициент сопротивления формы холмов, Grant & Mason 1990 / Wood & Mason 1993:
        0,1–0,6, не подгонялся) — «торможение массивом» §12 A;
        масса: ∫u dz до z_mass (верх области решателя над землёй) сохраняется — дефицит у земли уходит наверх
        равномерно в слое h_d…z_mass (у решателя жёсткие боковые границы: выход = приток × множитель).
    Источник: решатель air3d (то же замыкание и шероховатость; проверка — профиль решателя в среднем по области).
    Границы: без Кориолиса (как решатель), без формы рельефа (сопротивление формы — механизм A/D не даёт: линейная
    теория без среднего сопротивления, §12 A «торможение массивом»); профиль по разгону, а не по сетке.
    → массив (len(fetches), 13) — u(AGL_M) при каждом разгоне, м/с."""
    zf = np.concatenate([[0.0], np.geomspace(4.0, ztop, nz)])
    zc = 0.5 * (zf[1:] + zf[:-1])
    dz = np.diff(zf)
    u = bg_profile(zc, u_sat, alpha, max_profile)
    u0 = u.copy()
    zm = ztop if z_mass is None else min(float(z_mass), ztop)
    in_mass = zc < zm
    shape_m = in_mass & (zc >= drag_depth)
    fd = 0.5 * cd_form * drag_lambda / max(drag_depth, 1.0) * (zc < drag_depth)
    if u_sat <= 0:
        return np.zeros((len(fetches), len(AGL_M)))
    lam = max(LAM_M, LAM_FRAC * h)
    k_hb = _k_profile(zf[1:-1], ustar, wstar, h, L, unst)          # на внутренних гранях
    lmix = KAPPA * zf[1:-1] / (1 + KAPPA * zf[1:-1] / lam)
    cd = (KAPPA / math.log(zc[0] / Z0)) ** 2
    hz = np.diff(zc)
    order = np.argsort(fetches)
    out = np.zeros((len(fetches), len(AGL_M)))
    x = 0.0
    q = 0
    fs = np.asarray(fetches, np.float64)
    while q < len(order) and fs[order[q]] <= 0:
        out[order[q]] = np.interp(AGL_M, zc, u)
        q += 1
    while q < len(order):
        sh = np.abs(np.diff(u)) / hz
        K = np.maximum(k_hb, lmix ** 2 * sh)
        uadv = max(float(np.mean(u[zc < 500.0])), 0.3)
        dt = dd / uadv
        # неявная схема: (u_new − u)/dt = [K_{k+½}(u_{k+1} − u_k)/hz_k − K_{k−½}(u_k − u_{k−1})/hz_{k−1}]/dz_k
        n = len(zc)
        a = np.zeros(n); b = np.ones(n); c = np.zeros(n); d = u.copy()
        up = K / hz                                              # n−1 граней
        a[1:] = -dt * up / dz[1:]
        c[:-1] = -dt * up / dz[:-1]
        b[1:] += dt * up / dz[1:]
        b[:-1] += dt * up / dz[:-1]
        b[0] += dt * cd * abs(u[0]) / dz[0]
        b += dt * fd * np.abs(u)
        a[-1] = 0.0; c[-1] = 0.0; b[-1] = 1.0; d[-1] = u_sat      # верх — U_sat
        ab = np.zeros((3, n)); ab[0, 1:] = c[:-1]; ab[1] = b; ab[2, :-1] = a[1:]
        u = solve_banded((1, 1), ab, d)
        if drag_lambda > 0 and np.any(shape_m):
            deficit = float(np.sum((u0 - u)[in_mass] * dz[in_mass]))
            u[shape_m] += deficit / float(np.sum(dz[shape_m]))
        x_new = x + dd
        while q < len(order) and fs[order[q]] <= x_new:
            out[order[q]] = np.interp(AGL_M, zc, u)
            q += 1
        x = x_new
    return out


def background_field(hc, cond, heat, *, dd=250.0, n_bins=24):
    """Фон по клеткам: профиль столба `column_bl` при разгоне клетки (`fetch_m`) и её K (h, w*, L из `bl_state`).
    Клетки группируются по (h, w*, L) в n_bins квантилей (численное упрощение; без нагрева столб один на всю
    область). → U (13, ny, nx) — скорость вдоль ветра e, м/с; bl — dict bl_state."""
    hc = np.asarray(hc, np.float64)
    e = wind_unit(cond["wind_from_deg"])
    u10 = float(cond["u10_m_s"])
    bl = bl_state(hc, heat, float(cond["z_i_m"]), u10)
    fe = fetch_m(e, hc.shape[0])
    fq = np.linspace(0.0, 60000.0, 121)
    gy, gx = np.gradient(hc, DX)
    lam_f = float(np.mean(np.maximum(gx * e[0] + gy * e[1], 0.0)))
    h_d = max(2.0 * float(np.std(hc)), 100.0)
    z_mass = float(hc.max() - hc.mean()) + 2000.0                 # верх решателя max+3000, губка — верхний 1 км
    U = np.zeros((len(AGL_M),) + hc.shape)
    if u10 <= 0:
        return U, bl
    key_h = bl["h"]
    key_w = bl["wstar"]
    stable = np.isfinite(bl["L"])
    keyL = np.where(stable, 1.0 / np.where(stable, bl["L"], 1.0), 0.0)
    # бины: по h·(1 + w*) и 1/L — квантили (столбов немного; численное упрощение)
    score = np.log(key_h) + 0.5 * key_w - 50.0 * keyL
    flat = score.ravel()
    if np.ptp(flat) < 1e-6:
        labels = np.zeros(flat.size, int)
        nb = 1
    else:
        qs = np.quantile(flat, np.linspace(0, 1, n_bins + 1))
        labels = np.clip(np.searchsorted(qs, flat, side="right") - 1, 0, n_bins - 1)
        nb = n_bins
    fflat = fe.ravel()
    Uf = U.reshape(len(AGL_M), -1)
    for bi in range(nb):
        sel = labels == bi
        if not np.any(sel):
            continue
        hb = float(np.median(key_h.ravel()[sel]))
        wb = float(np.median(key_w.ravel()[sel]))
        un = bool(np.median(bl["unst"].ravel()[sel].astype(float)) > 0.5)
        Ls = keyL.ravel()[sel]
        Lb = 1.0 / float(np.median(Ls)) if (not un and np.median(Ls) != 0) else np.inf
        prof = column_bl(float(cond["u_sat_m_s"]), float(cond["alpha"]), float(cond["max_profile"]), bl["ustar"],
                         wb, hb, Lb, un, fq, dd=dd, ztop=z_mass + 1000.0, drag_lambda=lam_f, drag_depth=h_d,
                         z_mass=z_mass)                # (len(fq), 13)
        fx = fflat[sel]
        for k in range(len(AGL_M)):
            Uf[k, sel] = np.interp(fx, fq, prof[:, k])
    return U, bl


# ============================================================================ A: линейная теория через DCT
def _dct_amp(a):
    """Амплитуды разложения по cos(π p (i+½)/N) cos(π q (j+½)/N) — DCT-II (scipy.fft.dctn, ortho) → амплитуды."""
    c = sfft.dctn(np.asarray(a, np.float64), type=2, norm="ortho")
    ny, nx = c.shape
    sy = np.full(ny, math.sqrt(2.0 / ny)); sy[0] = math.sqrt(1.0 / ny)
    sx = np.full(nx, math.sqrt(2.0 / nx)); sx[0] = math.sqrt(1.0 / nx)
    return c * sy[:, None] * sx[None, :]


def _basis(n):
    i = np.arange(n) + 0.5
    p = np.arange(n)
    C = np.cos(np.pi * np.outer(i, p) / n)
    S = np.sin(np.pi * np.outer(i, p) / n)
    return C, S


_BASIS = {}


def _synth(Tcoef, amp, n):
    """Синтез Re Σ T(k,l)·a_pq·e^{i(kx+ly)} по чётному продолжению (матричным умножением, как DCT на GPU §15.2):
    T раскладывается на чётные/нечётные по k и l части; cos·cos → CC, нечётная по k → i·sin·cos и т. д.
    Tcoef — dict {(sk, sl): T(sk·k, sl·l)} для sk, sl ∈ {+1, −1}; amp — (ny, nx) амплитуды."""
    if n not in _BASIS:
        _BASIS[n] = _basis(n)
    C, S = _BASIS[n]
    Tpp, Tmp, Tpm, Tmm = Tcoef[(1, 1)], Tcoef[(-1, 1)], Tcoef[(1, -1)], Tcoef[(-1, -1)]
    Tee = 0.25 * (Tpp + Tmp + Tpm + Tmm)
    Toe = 0.25 * (Tpp - Tmp + Tpm - Tmm)      # нечётная по k (ось x — i)
    Teo = 0.25 * (Tpp + Tmp - Tpm - Tmm)      # нечётная по l (ось y — j)
    Too = 0.25 * (Tpp - Tmp - Tpm + Tmm)
    # поле[j, i] = Σ_{q,p} X[q,p]·Yb[j,q]·Xb[i,p]  → Yb @ X @ Xb.T; amp вещественна — только вещественные умножения
    res = C @ (np.real(Tee) * amp) @ C.T
    res -= C @ (np.imag(Toe) * amp) @ S.T
    res -= S @ (np.imag(Teo) * amp) @ C.T
    res -= S @ (np.real(Too) * amp) @ S.T
    return res


def jh_scales(Kmag):
    """Масштабы Джексона–Ханта [JH75] для моды с |K|: L = 1/|K|; внутренний слой ℓ: ℓ·ln(ℓ/z0) = 2κ²L;
    средний слой h_m: h_m·√ln(h_m/z0) = L (итерацией)."""
    L = 1.0 / np.maximum(Kmag, 1e-12)
    ell = np.full_like(L, 10.0)
    hm = np.full_like(L, 100.0)
    for _ in range(30):
        ell = 2 * KAPPA ** 2 * L / np.log(np.maximum(ell, 2 * Z0) / Z0)
        hm = L / np.sqrt(np.log(np.maximum(hm, 2 * Z0) / Z0))
    return np.maximum(ell, 2 * Z0), np.maximum(hm, 2 * Z0)


def linear_a(h, e, U_of_z, n_bv, *, z_levels=AGL_M, dx=DX, damp_m=20000.0, cap_frac=0.8, U_level=None, eta=False):
    """Механизм A — линейная теория обтекания (нейтральная [JH75] и устойчивая гидростатическая/негидростатическая
    [Sm80]) по 13 уровням, разложение рельефа по DCT-II (чётное продолжение, непериодичность — как P3):
        η̂(k, l, z) = ĥ·exp(i m z),  ŵ = i σ η̂,  (û, v̂) = −(k, l)·m·ŵ/|K|²  (поляризация из импульса и неразрывности),
        σ = U_ref·(e·K) − iε в дисперсии (ε = U_ref/damp_m — затухание волн, чтобы чётное продолжение не возвращало
        их в область; в амплитуде ŵ — вещественная σ, иначе ε даёт ложный w ∝ h),
        m² = (N²/σ² − 1)|K|²: σ² < N² — волна вверх, m = sign(Re σ)·√…; иначе затухание m = i·√(1 − N²/σ²)|K|
        (N = 0 — потенциальное обтекание, внешний слой JH75: û = U|K|ĥ над вершиной).
        U_ref(K) = U(h_m(K)) — скорость на высоте среднего слоя JH75; внутренний слой (z < ℓ(K)): возмущение
        горизонтальной скорости ∝ U(z) (постоянная доля разгона ΔS), т. е. û(z) = û(ℓ)·U(z)/U(ℓ).
    Высота z — над землёй (приближение «следования рельефу», как MS3DJH/WAsP): допустимо при h/a ≲ 0,2–0,3.
    Источник: Jackson & Hunt 1975 (QJRMS 101), Smith 1980 (Tellus 32), Finnigan et al. 2020 (BLM 177), §12 A.
    Границы: h/a > 0,2–0,3 (срыв — механизм LEE), Fr < 1 (блокирование — механизм D, A — на срезанном рельефе),
    Nh/U ≳ 0,5–1 (нелинейные волны — C, не умеем); торможения массивом в целом нет (фон — `column_bl`).
    Возмущение горизонтальной скорости ограничено cap_frac·U(z) (численная страховка линейной теории, помечено).
    → (du, dv, dw) — каждое (13, ny, nx), м/с; U_level (13,) — фон на уровнях для ограничения; eta=True — ещё
    смещение линии тока η (13, ny, nx), м (для θ′ = −dθ̄/dz·η)."""
    h = np.asarray(h, np.float64)
    ny, nx = h.shape
    n = nx
    assert ny == nx, "квадратная область"
    amp = _dct_amp(h - h.mean())
    amp[0, 0] = 0.0
    kk = np.pi * np.arange(n) / (n * dx)
    Kx = kk[None, :]
    Ky = kk[:, None]
    Kmag = np.sqrt(Kx ** 2 + Ky ** 2)
    Kmag[0, 0] = 1.0
    ell, hm = jh_scales(Kmag)
    Uref = U_of_z(hm)
    Uref = np.maximum(Uref, 0.1)
    eps = Uref / damp_m
    nz = len(z_levels)
    du = np.zeros((nz, ny, nx)); dv = np.zeros_like(du); dw = np.zeros_like(du); de = np.zeros_like(du)
    coefs = {}
    for sk in (1, -1):
        for sl in (1, -1):
            kx, ly = sk * Kx * np.ones_like(Ky), sl * Ky * np.ones_like(Kx)
            sig = Uref * (e[0] * kx + e[1] * ly) - 1j * eps
            ratio = (n_bv ** 2) / (sig ** 2)
            m2 = (ratio - 1.0) * Kmag ** 2
            m = np.sqrt(m2 + 0j)
            # ветвь: волна уходит вверх (знак Re m = знак Re σ, излучение энергии вверх), затухание с высотой (Im m ≥ 0)
            m = np.abs(np.real(m)) * np.sign(np.real(sig) + 1e-30) + 1j * np.abs(np.imag(m))
            coefs[(sk, sl)] = (kx, ly, sig, m)
    for iz, z in enumerate(z_levels):
        zeff = np.maximum(z, ell)                                  # внешнее решение — не ниже ℓ
        inner = U_of_z(np.full(1, z))[0] / np.maximum(U_of_z(ell), 1e-6)
        inner = np.where(z < ell, np.minimum(inner, 1.0), 1.0)
        Tw, Tu, Tv, Te = {}, {}, {}, {}
        for key, (kx, ly, sig, m) in coefs.items():
            ez = np.exp(1j * m * zeff)
            what = 1j * np.real(sig) * ez                  # ε — только в дисперсии (затухание), не в амплитуде
            uh = -kx * m * what / Kmag ** 2 * inner
            vh = -ly * m * what / Kmag ** 2 * inner
            wz = 1j * np.real(sig) * np.exp(1j * m * z)   # w — на самой высоте (у земли U·∇h)
            for T, val in ((Tw, wz), (Tu, uh), (Tv, vh), (Te, np.exp(1j * m * z))):
                val = np.array(val)
                val[0, 0] = 0.0
                T[key] = val
        dw[iz] = _synth(Tw, amp, n)
        du[iz] = _synth(Tu, amp, n)
        dv[iz] = _synth(Tv, amp, n)
        if eta:
            de[iz] = _synth(Te, amp, n)
    if U_level is not None and cap_frac is not None:
        mag = np.sqrt(du ** 2 + dv ** 2)
        lim = cap_frac * np.maximum(np.asarray(U_level, np.float64), 0.0)
        if lim.ndim == 1:
            lim = lim[:, None, None]
        fac = np.where(mag > lim, lim / np.maximum(mag, 1e-9), 1.0)
        du *= fac; dv *= fac
    if eta:
        return du, dv, dw, de
    return du, dv, dw


# ============================================================================ D: разделяющая линия тока + слои Лапласа
def dividing_height(hc, froude):
    """Разделяющая линия тока [She56, Sny85]: H_c = base + (h_max − base)·(1 − Fr) при Fr < 1, иначе base;
    base — 5-й процентиль рельефа (равнина), h_max — максимум. Ниже H_c воздух обходит препятствия, выше — переваливает.
    Границы: хорошо для симметричных холмов при малом сдвиге; нижняя оценка при сдвиге/асимметрии; при h < z_i
    (рельеф не пробивает слой перемешивания) блокирования нет — это учтено в Fr (N над z_i)."""
    base = float(np.percentile(hc, 5))
    hmax = float(np.max(hc))
    fr = float(froude)
    return base + (hmax - base) * max(0.0, 1.0 - fr), base


def layer_potential(wall, e, dx=DX):
    """Двумерное безвихревое обтекание стенок (клетки wall = рельеф выше слоя) в слое: ∇²φ = 0 в воздухе, ∂φ/∂n = 0 на
    стенках (непротекание), φ = e·x на внешнем кольце клеток; u_h = ∇φ (единичный набегающий поток). Несжимаемо в
    слое по построению, w = 0. Предел Fr → 0 (Drazin 1961) — верно при Fr ≲ 0,3, при 0,3–0,5 слой частично переваливает.
    Замкнутые котловины (воздух, не связанный с краем) — φ = 0 (застой, малая регуляризация). Проход через седловины —
    автоматически (ускорение в сужениях). Источник: §12 D (вместо ψ с ∂ψ/∂n = 0 — потенциал: то же условие
    непротекания без неизвестных постоянных ψ на островах). → (gx, gy) (ny, nx) — скорость в долях набегающей."""
    ny, nx = wall.shape
    fluid = ~wall
    idx = -np.ones((ny, nx), int)
    ring = np.zeros((ny, nx), bool)
    ring[0, :] = ring[-1, :] = ring[:, 0] = ring[:, -1] = True
    unk = fluid & ~ring
    idx[unk] = np.arange(unk.sum())
    xc = (np.arange(nx) + 0.5) * dx
    X, Y = np.meshgrid(xc, xc)
    phib = (e[0] * X + e[1] * Y) / dx                           # в единицах dx
    nU = int(unk.sum())
    if nU == 0:
        return np.zeros((ny, nx)), np.zeros((ny, nx))
    rows, cols, vals = [], [], []
    rhs = np.zeros(nU)
    diag = np.full(nU, 1e-9)
    J, I = np.nonzero(unk)
    me = idx[J, I]
    for dj, di in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        jn, in_ = J + dj, I + di
        f_n = fluid[jn, in_]
        diag += f_n
        u_n = unk[jn, in_]
        rows.append(me[u_n]); cols.append(idx[jn[u_n], in_[u_n]]); vals.append(-np.ones(u_n.sum()))
        b_n = f_n & ~unk[jn, in_]
        np.add.at(rhs, me[b_n], phib[jn[b_n], in_[b_n]])
    rows.append(me); cols.append(me); vals.append(diag)
    A = sp.csr_matrix((np.concatenate(vals), (np.concatenate(rows), np.concatenate(cols))), shape=(nU, nU))
    sol = spla.spsolve(A.tocsc(), rhs)
    phi = np.where(fluid, phib, 0.0)
    phi[unk] = sol
    # скорости на гранях (в долях набегающей, φ в единицах dx): стенка — 0
    fx = np.zeros((ny, nx + 1)); fy = np.zeros((ny + 1, nx))
    okx = fluid[:, 1:] & fluid[:, :-1]
    fx[:, 1:-1] = np.where(okx, phi[:, 1:] - phi[:, :-1], 0.0)
    fx[:, 0] = np.where(fluid[:, 0], e[0], 0.0); fx[:, -1] = np.where(fluid[:, -1], e[0], 0.0)
    oky = fluid[1:, :] & fluid[:-1, :]
    fy[1:-1, :] = np.where(oky, phi[1:, :] - phi[:-1, :], 0.0)
    fy[0, :] = np.where(fluid[0, :], e[1], 0.0); fy[-1, :] = np.where(fluid[-1, :], e[1], 0.0)
    gx = np.where(fluid, 0.5 * (fx[:, 1:] + fx[:, :-1]), 0.0)
    gy = np.where(fluid, 0.5 * (fy[1:, :] + fy[:-1, :]), 0.0)
    return gx, gy


def blocked_layers(hc, Hc, base, e, dz_layer=100.0, max_layers=12):
    """Слои Лапласа от base до H_c (шаг ≥ dz_layer, не больше max_layers): → (z_layers, gx, gy) — gx, gy (L, ny, nx)."""
    if Hc <= base + 1.0:
        return np.zeros(0), np.zeros((0,) + hc.shape), np.zeros((0,) + hc.shape)
    nL = int(min(max_layers, max(1, math.ceil((Hc - base) / dz_layer))))
    zL = base + (np.arange(nL) + 0.5) * (Hc - base) / nL
    gx = np.zeros((nL,) + hc.shape); gy = np.zeros_like(gx)
    for q, z in enumerate(zL):
        gx[q], gy[q] = layer_potential(hc > z, e)
    return zL, gx, gy


# ============================================================================ срыв: огибающая 12° (AP-10) и пузырь
def envelope(hc, wdir_from_deg, angle_deg=12.0, dx=DX):
    """h_eff = max(h, линия тени) — копия `air_phase/batch_solver.envelope` (P4 v2, AP-10): марш по ветру,
    h_eff(p) = max(h(p), h_eff(p − e·dx) − dx·tg угла), билинейно, итерации до неподвижной точки. Угол 12° — игра
    (lee.shadow_angle_deg), AP-10: опыт 9,9° [7,4; 11,8], литература 16–32° (3D); рекомендация AP-10 — 12°."""
    hc = np.asarray(hc, float)
    if angle_deg <= 0:
        return hc.copy()
    ex, ey = wind_unit(wdir_from_deg)
    drop = dx * math.tan(math.radians(angle_deg))
    ny, nx = hc.shape
    J, I = np.indices(hc.shape).astype(float)
    fi, fj = I - ex, J - ey
    ok = (fi >= 0) & (fi <= nx - 1) & (fj >= 0) & (fj <= ny - 1)
    i0 = np.clip(np.floor(fi).astype(int), 0, nx - 2)
    j0 = np.clip(np.floor(fj).astype(int), 0, ny - 2)
    a, b = fi - i0, fj - j0
    he = hc.copy()
    for _ in range(4 * max(hc.shape)):
        v = (1 - b) * ((1 - a) * he[j0, i0] + a * he[j0, i0 + 1]) + b * ((1 - a) * he[j0 + 1, i0] + a * he[j0 + 1, i0 + 1])
        up = np.where(ok, v, -np.inf)
        new = np.maximum(hc, up - drop)
        if np.array_equal(new, he):
            break
        he = new
    return he


def bubble_profile(z, depth, u_top, reverse=0.2):
    """Пузырь срыва под линией тени (механизм B, §12): u(z)/U_top = −r + (1 + r)·(z/d)², z < d = h_eff − h;
    r = 0,2 — обратный ветер ≈ 0,2·U₁₀₀ (Perdigão, air_physics_primer §3.3; AP-10: 0,6–0,8 по полю окна 100 м против
    литературы 0,6–0,8 в долях другой нормировки — берём литературу); w = 0. Наверху пузыря скорость = U_top (сшивка
    с обтеканием огибающей). Границы: нестационарный отрыв и пульсации — масштаб 3; длина пузыря у K-замыкания длиннее
    (AP-10), здесь — по огибающей 12°."""
    t = np.clip(np.asarray(z, np.float64) / np.maximum(depth, 1e-6), 0.0, 1.0)
    return u_top * (-reverse + (1.0 + reverse) * t ** 2)


# ============================================================================ E/F: θ′, анабатика, статистика подобия
def theta_march(Hk, h_bl, U_ml, e, dx=DX, tau=TAU_COOL, sweeps=None):
    """θ′ слоя перемешивания — стационарный баланс тепла столба вдоль ветра (полулагранжев марш, как огибающая):
        U·∂θ′/∂s = H_k/h − θ′/τ  ⇒  θ′(p) = θ′(p − e·dx)·exp(−Δt/τ) + (H_k/h)·τ·(1 − exp(−Δt/τ)),  Δt = dx/U,
    H_k = H/(ρc_p), h — толщина слоя (нагрев cbl решателя: H равномерно по h), τ = 7200 с (Params.tau_cool).
    При U → 0 θ′ → H_k·τ/h (местное равновесие). Охлаждение (H < 0) — в слое h тем же балансом (устойчивый
    приземный слой тоньше — грубо, помечено). Границы: без горизонтальной диффузии и без адвекции через верх слоя;
    θ′ фона над z_i не меняется. Источник: air3d (нагрев cbl, τ), баланс — §12 E/F «среднее поле из баланса»."""
    ny, nx = Hk.shape
    U = np.maximum(U_ml, 0.3)
    dt = dx / U
    a = np.exp(-dt / tau)
    src = Hk / np.maximum(h_bl, 1.0) * tau * (1 - a)
    J, I = np.indices((ny, nx)).astype(float)
    fi, fj = I - e[0], J - e[1]
    ok = (fi >= 0) & (fi <= nx - 1) & (fj >= 0) & (fj <= ny - 1)
    i0 = np.clip(np.floor(fi).astype(int), 0, nx - 2)
    j0 = np.clip(np.floor(fj).astype(int), 0, ny - 2)
    aa, bb = fi - i0, fj - j0
    th = src.copy()
    for _ in range(sweeps or 2 * max(ny, nx)):
        v = (1 - bb) * ((1 - aa) * th[j0, i0] + aa * th[j0, i0 + 1]) + bb * ((1 - aa) * th[j0 + 1, i0] + aa * th[j0 + 1, i0 + 1])
        new = np.where(ok, v, 0.0) * a + src
        if np.max(np.abs(new - th)) < 1e-5:
            th = new
            break
        th = new
    return th


def anabatic(hc, Hk, h_bl, dx=DX, slope_len_m=2000.0):
    """Анабатический (склоновый) ветер днём — простая форма (помечено): скорость вверх по склону
    u_a = (B_s·L·sin α)^(1/3), B_s = g·H_k/θ0 — поток плавучести у земли, L — длина склона (2 км, численное
    допущение), в слое δ = max(50 м, 0,1h) у земли (приземный слой), затухание выше как exp(−z/δ). Масштаб — подобие
    Hunt, Fernando & Princevac 2003 (JAS 60) по памяти, проверить; наблюдения 1–5 м/с, 20–200 м [ZW13].
    Подъём над гребнями и опускание над долинами даёт проекция ∇·u = 0 (сходимость потоков у гребней).
    Границы: не учитывает ветер (сдувается при U ≳ 3–5 м/с — домножается на вес E/F), валы и ячейки, кромку облаков.
    → (au, av) (13, ny, nx)."""
    gy, gx = np.gradient(hc, dx)
    s = np.sqrt(gx ** 2 + gy ** 2)
    sina = s / np.sqrt(1 + s ** 2)
    Bs = G / THETA0 * np.maximum(Hk, 0.0)
    ua = (Bs * slope_len_m * sina) ** (1 / 3)
    nx_, ny_ = gx / np.maximum(s, 1e-9), gy / np.maximum(s, 1e-9)
    delta = np.maximum(50.0, 0.1 * h_bl)
    prof = np.exp(-AGL_M[:, None, None] / delta[None])
    return ua[None] * nx_[None] * prof, ua[None] * ny_[None] * prof


def similarity_sigma_w(wstar, h_bl):
    """σ_w(z) слоя перемешивания [LWP80]: σ_w²/w*² = 1,8·(z/z_i)^(2/3)·(1 − 0,8 z/z_i)², z < z_i (выше 0) —
    статистика E/F (не входит в среднее поле, отдаётся отдельно). → (13, ny, nx), м/с."""
    zr = AGL_M[:, None, None] / np.maximum(h_bl[None], 1.0)
    v = 1.8 * np.clip(zr, 0, 1) ** (2 / 3) * np.clip(1 - 0.8 * zr, 0, None) ** 2
    return wstar[None] * np.sqrt(np.where(zr < 1, v, 0.0))


# ============================================================================ проекция ∇·u = 0 (один шаг)
def _cell_geom():
    dzc = np.diff(ZF)                                  # толщины ячеек (13)
    zc = 0.5 * (ZF[1:] + ZF[:-1])                      # центры ячеек
    return dzc, zc


def divergence_faces(u, v, W, dx=DX):
    """Дивергенция в координатах ζ = z − h(x, y) (якобиан 1): ∂u/∂x|ζ + ∂v/∂y|ζ + ∂W̃/∂ζ, W̃ = w − u·h_x − v·h_y —
    скорость относительно поверхности рельефа. Сетка MAC: u, v — на гранях (среднее соседних центров; на боковых
    гранях — значение крайней клетки), W̃ — на гранях по высоте (у земли 0; наверху — экстраполяция). → div (13, ny, nx),
    фейсы (fx, fy, fz)."""
    dzc, zc = _cell_geom()
    nz, ny, nx = u.shape
    fx = np.empty((nz, ny, nx + 1)); fx[:, :, 1:-1] = 0.5 * (u[:, :, 1:] + u[:, :, :-1]); fx[:, :, 0] = u[:, :, 0]; fx[:, :, -1] = u[:, :, -1]
    fy = np.empty((nz, ny + 1, nx)); fy[:, 1:-1, :] = 0.5 * (v[:, 1:, :] + v[:, :-1, :]); fy[:, 0, :] = v[:, 0, :]; fy[:, -1, :] = v[:, -1, :]
    fz = np.zeros((nz + 1, ny, nx))
    t = ((ZF[1:-1] - AGL_M[:-1]) / (AGL_M[1:] - AGL_M[:-1]))[:, None, None]
    fz[1:-1] = (1 - t) * W[:-1] + t * W[1:]
    fz[-1] = W[-1]
    div = (fx[:, :, 1:] - fx[:, :, :-1]) / dx + (fy[:, 1:, :] - fy[:, :-1, :]) / dx + (fz[1:] - fz[:-1]) / dzc[:, None, None]
    return div, (fx, fy, fz)


def project(u, v, w, hc, dx=DX):
    """Один шаг проекции (массосогласование, Sherman 1978 / [Ros88]; §15.3): ∇²φ = ∇·u, u ← u − ∇φ на сетке MAC в
    координатах ζ = z − h. Граничные условия: у земли W̃ = 0 (∂φ/∂n = 0), боковые грани — поток задан (∂φ/∂n = 0,
    как жёсткие границы решателя), наверху φ = 0 (поток через верх свободен). Решение точное для дискретной задачи:
    DCT-II по горизонтали (собственные числа 5-точечного оператора Неймана) + прогонка по 13 уровням для каждой моды.
    Метрические перекрёстные члены оператора (∂h/∂x·∂/∂ζ) в лапласиане опущены (поправка W̃ ↔ w их учитывает
    через W̃ = w − u·∇h) — после проекции дивергенция на гранях — ноль до округления, на центрах — малая (интерполяция).
    → (u, v, w, info) — info: rms/max |div| до и после (на гранях и в центрах), 1/с."""
    nz, ny, nx = u.shape
    gy, gx = np.gradient(hc, dx)
    W = w - u * gx[None] - v * gy[None]
    div0, (fx, fy, fz) = divergence_faces(u, v, W, dx)
    dzc, zc = _cell_geom()
    # горизонталь: DCT-II, λ_p = (2cos(πp/N) − 2)/dx²
    lam_x = (2 * np.cos(np.pi * np.arange(nx) / nx) - 2) / dx ** 2
    lam_y = (2 * np.cos(np.pi * np.arange(ny) / ny) - 2) / dx ** 2
    lam = lam_y[:, None] + lam_x[None, :]
    rhs = sfft.dctn(div0, type=2, axes=(1, 2), norm="ortho")
    # вертикаль: (φ_{k+1} − φ_k)/hz_k − (φ_k − φ_{k−1})/hz_{k−1}, делённое на dzc_k; низ — Нейман, верх — φ = 0 на грани
    hz = np.diff(zc)
    a = np.zeros(nz); c = np.zeros(nz); b = np.zeros(nz)
    a[1:] = 1.0 / (hz * dzc[1:])
    c[:-1] = 1.0 / (hz * dzc[:-1])
    b[1:] -= a[1:]
    b[:-1] -= c[:-1]
    htop = ZF[-1] - zc[-1]
    b[-1] -= 1.0 / (htop * dzc[-1])
    A_ = np.broadcast_to(a[:, None, None], rhs.shape).copy()
    C_ = np.broadcast_to(c[:, None, None], rhs.shape).copy()
    B_ = b[:, None, None] + lam[None]
    phi_h = _thomas(A_.reshape(nz, -1), B_.reshape(nz, -1), C_.reshape(nz, -1), rhs.reshape(nz, -1)).reshape(rhs.shape)
    phi = sfft.idctn(phi_h, type=2, axes=(1, 2), norm="ortho")
    fx = fx.copy(); fy = fy.copy(); fz = fz.copy()
    fx[:, :, 1:-1] -= (phi[:, :, 1:] - phi[:, :, :-1]) / dx
    fy[:, 1:-1, :] -= (phi[:, 1:, :] - phi[:, :-1, :]) / dx
    fz[1:-1] -= (phi[1:] - phi[:-1]) / hz[:, None, None]
    fz[-1] -= (0.0 - phi[-1]) / htop
    div_f = (fx[:, :, 1:] - fx[:, :, :-1]) / dx + (fy[:, 1:, :] - fy[:, :-1, :]) / dx + (fz[1:] - fz[:-1]) / dzc[:, None, None]
    un = 0.5 * (fx[:, :, 1:] + fx[:, :, :-1])
    vn = 0.5 * (fy[:, 1:, :] + fy[:, :-1, :])
    # W̃ на уровнях AGL_M — линейно по граням
    Wn = np.empty_like(u)
    for k in range(nz):
        t = (AGL_M[k] - ZF[k]) / (ZF[k + 1] - ZF[k])
        Wn[k] = (1 - t) * fz[k] + t * fz[k + 1]
    wn = Wn + un * gx[None] + vn * gy[None]
    div_c, _ = divergence_faces(un, vn, Wn, dx)
    info = dict(div_rms_before=float(np.sqrt(np.mean(div0 ** 2))), div_max_before=float(np.abs(div0).max()),
                div_rms_faces=float(np.sqrt(np.mean(div_f ** 2))), div_max_faces=float(np.abs(div_f).max()),
                div_rms_centers=float(np.sqrt(np.mean(div_c ** 2))), div_max_centers=float(np.abs(div_c).max()))
    return un, vn, wn, info
