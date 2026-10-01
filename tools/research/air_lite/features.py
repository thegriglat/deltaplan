"""Признаки точки для суррогата поля (рельеф + погода) и прежняя аналитика игры для сравнения.

Всё считается из того, что есть у игры без решателя: рельеф (слой detail 25 м), ветер прогноза
(U10, откуда), погода часа (weather.Day: z_i, θ̄(z), поток тепла H — формула, не решение), профиль
притока (α, max_profile — WindProfile). Решение эталона здесь НЕ используется.

Система: x — восток, y — север; ê — куда дует ветер, ê⊥ — 90° влево от ê.

Признаки (по столбцу уровня; σ — гауссово сглаживание рельефа, м):
  tpi_σ        h_сетки − h̄_σ: топографическая позиция (σ = 100, 250, 500, 1000, 2000)
  gpar_σ       ∇h̄_σ·ê — уклон по ветру (> 0 — наветренный склон вверх), gper_σ — поперёк (σ = 100, 250, 500, 1000)
  gmag_σ       |∇h̄_σ|; lap_σ — лапласиан h̄_σ (кривизна, > 0 — ложбина)  (σ = 250, 1000)
  sx_d         укрытость с наветра (Winstral): max_d' atan((h(p − ê d') − h(p))/d'), d' ≤ d (d = 500, 1500, 4000)
  ahead_d      то же вперёд по ветру: подъём впереди (d = 1500)
  relief       превышение гребня против ветра (как GroundField.relief_at, 60…1600 м)
  pf_u, pf_v, pf_w  — линейное потенциальное обтекание (Jackson–Hunt, внешняя область; Fourier):
               û/U = (k_e²/|k|) ĥ e^{−|k|a}, v̂/U = (k_e k_⊥/|k|) ĥ e^{−|k|a}, ŵ/U = i k_e ĥ e^{−|k|a}
               (a — высота над землёй; рельеф — 100 м блоки по всему месту)
  ws_u, ws_w   то же в устойчивом слое (Smith 1980): m² = |k|²(N²/(U k_e)² − 1), излучение вверх
  Атмосфера: a, U10, Ubg(a) (фон решателя), α, N (над слоем перемешивания), h_bl, z_i − hc, H (в столбце),
             H_s1500 (сглаженный), sun_el, hour, sky_heat, t_max.
"""
from __future__ import annotations

import math
from functools import lru_cache

import numpy as np
from scipy.ndimage import gaussian_filter, map_coordinates

import places as P

SIG_TPI = (100, 250, 500, 1000, 2000)
SIG_G = (100, 250, 500, 1000)
SIG_C = (250, 1000)
SX_D = (500, 1500, 4000)
G, THETA0, KAPPA = 9.81, 300.0, 0.4


# ------------------------------------------------------------------ рельеф места
@lru_cache(maxsize=None)
def dem(loc):
    L = P.location(loc)
    return L.h, L.info


@lru_cache(maxsize=None)
def smooth(loc, sigma_m):
    h, info = dem(loc)
    return gaussian_filter(h, sigma_m / info["spacing"], mode="nearest")


def sample(loc, F, x, y):
    """F на сетке DEM (j — север) в точках x, y (м), билинейно."""
    _, info = dem(loc)
    s = info["spacing"]
    x, y = np.atleast_1d(x).astype(float), np.atleast_1d(y).astype(float)
    x, y = np.broadcast_arrays(x, y)
    return map_coordinates(F, [(y - info["y0"]) / s, (x - info["x0"]) / s], order=1, mode="nearest")


@lru_cache(maxsize=None)
def grad(loc, sigma_m):
    hs = smooth(loc, sigma_m)
    s = dem(loc)[1]["spacing"]
    gy, gx = np.gradient(hs, s)
    return gx, gy


@lru_cache(maxsize=None)
def lap(loc, sigma_m):
    gx, gy = grad(loc, sigma_m)
    s = dem(loc)[1]["spacing"]
    return np.gradient(gx, s, axis=1) + np.gradient(gy, s, axis=0)


@lru_cache(maxsize=None)
def coarse100(loc):
    """Рельеф места блоками 100 м (как окна) — для линейного обтекания."""
    h, info = dem(loc)
    f = 4
    n = (h.shape[0] - 1) // f
    hb = h[:n * f, :n * f].reshape(n, f, n, f).mean(axis=(1, 3))
    return hb, info["x0"] - 0.5 * info["spacing"], info["y0"] - 0.5 * info["spacing"], 100.0


def unit(wdir):
    a = math.radians(wdir)
    ex, ey = -math.sin(a), -math.cos(a)
    return ex, ey


# ------------------------------------------------------------------ линейное обтекание
_PF_CACHE = {}


def potential_flow(loc, wdir, N, U, agl):
    """(pf_u, pf_v, pf_w) на 100-м сетке места (ny, nx) для каждого a ∈ agl → массивы (nA, ny, nx),
    в долях U (u — по ветру, v — влево); N > 0 — устойчивый слой (Smith 1980), иначе потенциальное."""
    key = (loc, round(wdir, 1), round(N, 5), round(U, 2), tuple(agl))
    if key in _PF_CACHE:
        return _PF_CACHE[key]
    hb, x0, y0, d = coarse100(loc)
    n = hb.shape[0]
    M = 1 << int(math.ceil(math.log2(n * 1.5)))
    base = np.median(np.concatenate([hb[0], hb[-1], hb[:, 0], hb[:, -1]]))
    pad = np.full((M, M), base)
    # плавный край: окно Тьюки по краю рельефа
    wy = np.ones(n); r = n // 16
    wy[:r] = 0.5 * (1 - np.cos(np.pi * np.arange(r) / r)); wy[-r:] = wy[:r][::-1]
    pad[:n, :n] = base + (hb - base) * np.outer(wy, wy)
    hk = np.fft.rfft2(pad - base)
    ky = 2 * np.pi * np.fft.fftfreq(M, d)[:, None]
    kx = 2 * np.pi * np.fft.rfftfreq(M, d)[None, :]
    ex, ey = unit(wdir)
    ke = kx * ex + ky * ey
    kp = -kx * ey + ky * ex
    K = np.sqrt(kx ** 2 + ky ** 2)
    Ks = np.where(K > 0, K, 1.0)
    if N > 0 and U > 0.3:
        with np.errstate(divide="ignore", invalid="ignore"):
            q = np.where(np.abs(ke) > 1e-12, N ** 2 / (U * ke) ** 2, 1e12) - 1.0
        m2 = K ** 2 * q
        m = np.where(m2 >= 0, np.sign(ke) * np.sqrt(np.abs(m2)), 1j * np.sqrt(np.abs(m2)))
    else:
        m = 1j * K
    out = np.zeros((3, len(agl), n, n), np.float32)
    for ia, a in enumerate(agl):
        e = np.exp(1j * m * a)
        wh = 1j * ke * hk * e
        uh = -m * ke / Ks ** 2 * wh
        vh = -m * kp / Ks ** 2 * wh
        for c, F in enumerate((uh, vh, wh)):
            F = np.where(K > 0, F, 0)
            out[c, ia] = np.fft.irfft2(F, s=(M, M))[:n, :n]
    res = (out, x0, y0, d)
    if len(_PF_CACHE) > 64:
        _PF_CACHE.clear()
    _PF_CACHE[key] = res
    return res


def sample_grid(F, x0, y0, d, x, y):
    return map_coordinates(F, [(np.asarray(y) - y0) / d - 0.5, (np.asarray(x) - x0) / d - 0.5], order=1, mode="nearest")


# ------------------------------------------------------------------ столбцы уровня
@lru_cache(maxsize=None)
def column_static(loc, x0, y0, dx, nx, ny):
    """Признаки рельефа столбцов уровня, не зависящие от ветра: dict имя → (ny, nx)."""
    x = x0 + (np.arange(nx) + 0.5) * dx
    y = y0 + (np.arange(ny) + 0.5) * dx
    X, Y = np.meshgrid(x, y)
    f = {}
    h0 = sample(loc, dem(loc)[0], X, Y)
    for s in SIG_TPI:
        f[f"tpi_{s}"] = h0 - sample(loc, smooth(loc, s), X, Y)
    for s in SIG_C:
        gx, gy = grad(loc, s)
        f[f"gmag_{s}"] = np.hypot(sample(loc, gx, X, Y), sample(loc, gy, X, Y))
        f[f"lap_{s}"] = sample(loc, lap(loc, s), X, Y) * 1000.0      # 1/км
    for s in (500, 1000):
        gx, gy = grad(loc, s)
        f[f"gx_{s}"] = sample(loc, gx, X, Y)       # уклон на восток / север (склоновые ветры без ветра)
        f[f"gy_{s}"] = sample(loc, gy, X, Y)
    f["_X"], f["_Y"] = X, Y
    return f


def column_wind(loc, X, Y, wdir):
    """Признаки рельефа относительно ветра (ny, nx)."""
    ex, ey = unit(wdir)
    f = {}
    for s in SIG_G:
        gx, gy = grad(loc, s)
        sx, sy = sample(loc, gx, X, Y), sample(loc, gy, X, Y)
        f[f"gpar_{s}"] = sx * ex + sy * ey
        f[f"gper_{s}"] = -sx * ey + sy * ex
    h100 = smooth(loc, 100)
    hp = sample(loc, h100, X, Y)
    best = {d: np.full(X.shape, -1.0) for d in SX_D}
    rel = np.zeros(X.shape)
    for dd in np.arange(100.0, max(SX_D) + 1, 100.0):
        hu = sample(loc, h100, X - ex * dd, Y - ey * dd)
        t = np.arctan((hu - hp) / dd)
        for d in SX_D:
            if dd <= d:
                best[d] = np.maximum(best[d], t)
        if dd <= 1600:
            rel = np.maximum(rel, hu - hp)
    for d in SX_D:
        f[f"sx_{d}"] = best[d]
    ah = np.full(X.shape, -1.0)
    for dd in np.arange(100.0, 1501.0, 100.0):
        ah = np.maximum(ah, np.arctan((sample(loc, h100, X + ex * dd, Y + ey * dd) - hp) / dd))
    f["ahead_1500"] = ah
    f["relief"] = rel
    return f


def n_eff(day, z_ground, depth=1000.0):
    """N над слоем перемешивания (или у земли, если слой тонкий): средний dθ̄/dz в depth над max(z_i, земля)."""
    z0 = max(day.z_i, z_ground)
    z = np.linspace(z0, z0 + depth, 21)
    gam = float(np.mean(day.gamma(z)))
    return math.sqrt(max(G / THETA0 * gam, 0.0))


def ubg(agl, alpha, max_profile, U10, z0=0.1):
    z_sat = 10.0 * max_profile ** (1.0 / alpha)
    return U10 * max_profile * np.minimum((np.maximum(agl, z0) / z_sat) ** alpha, 1.0)


# ------------------------------------------------------------------ прежняя аналитика игры
class Analytic:
    """atmosphere.gd → air_velocity_at без поля, только среднее (без шума, рывков, гроз, волн, термиков):
    горизонталь U10·profile(agl)·altitude_factor вдоль ветра (WindModel), w_ridge (_ridge_lift),
    линия тени и подветренный поток (_lee_flow: опускание и обратный поток у земли).
    Коэффициенты — configs/atmosphere.json (ridge, lee, wind)."""

    def __init__(self, cfg):
        self.r = cfg["ridge"]; self.l = cfg["lee"]; self.w = cfg["wind"]
        self.tan_sh = math.tan(math.radians(self.l["shadow_angle_deg"]))

    def eval(self, loc, X, Y, Z, U10, wdir, alpha, max_f, ref_msl):
        """X, Y, Z (м, Z над морем) — массивы одной формы → (u, v, w), u, v — восток, север."""
        h25, info = dem(loc)
        gx, gy = grad(loc, 25)       # склон по слою detail (у игры — узлы 30 м)
        ex, ey = unit(wdir)
        hg = sample(loc, h25, X, Y)
        agl = np.maximum(Z - hg, 0.0)
        prof = np.minimum((np.maximum(agl, self.w["roughness_height_m"]) / 10.0) ** alpha, max_f)
        alt = np.clip(1 + self.w["altitude_gain_per_km"] * (Z - ref_msl) / 1000.0, self.w["altitude_min_factor"],
                      self.w["altitude_max_factor"])
        u = U10 * prof * alt
        # линия тени и превышение гребня против ветра
        sh = np.full(X.shape, -1e9); rel = np.zeros(X.shape)
        for d in self.l["upwind_distances_m"]:
            hu = sample(loc, h25, X - ex * d, Y - ey * d)
            sh = np.maximum(sh, hu - d * self.tan_sh)
            rel = np.maximum(rel, hu - hg)
        depth = sh - Z
        l = self.l
        lee = np.where((depth > -l["shear_layer_m"]) & (u > 0),
                       np.clip((depth + l["shear_layer_m"]) / (l["depth_scale_m"] + l["shear_layer_m"]), 0, 1)
                       * np.clip(rel / l["relief_scale_m"], 0, 1), 0.0)
        uref = U10 * alt
        t = np.clip((uref - l["danger_min_wind_ms"]) / (l["danger_full_wind_ms"] - l["danger_min_wind_ms"]), 0, 1)
        danger = t * t * (3 - 2 * t)
        # склоновый подъём
        r = self.r
        shift = np.minimum(agl * r["forward_shift_factor"], r["forward_shift_max_m"])
        xs, ys = X + ex * shift, Y + ey * shift
        slope = ex * sample(loc, gx, xs, ys) + ey * sample(loc, gy, xs, ys)
        agl_s = np.maximum(Z - sample(loc, h25, xs, ys), 0.0)
        w_ridge = np.clip(r["efficiency"] * u * slope * np.exp(-agl_s / r["decay_height_m"]), -r["max_lift_ms"], r["max_lift_ms"])
        w = w_ridge * (1 - lee)
        hsp = u * (1 - lee * l["wind_reduction"])
        w = w - (l["sink_per_wind"] + (l["danger_sink_per_wind"] - l["sink_per_wind"]) * danger) * u * lee
        core = lee * danger * np.exp(-agl / np.maximum(l["rotor_height_fraction"] * rel, 1.0))
        hsp = hsp - l["rotor_reverse"] * u * core
        return hsp * ex, hsp * ey, w
