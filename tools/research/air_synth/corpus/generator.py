"""Генератор модельных рельефов корпуса air-synth (S3 v1): поле поднятия из форм плана §2 + анизотропное гауссово поле,
неоднородная прочность пород K, речная эрозия (stream power law, fastscapelib) + линейная диффузия + тепловая эрозия
до tan 35°, расчёт 512² × 100 м, берётся центр 384².

Смесь типов непрерывная: mix ∈ [0, 1] (0 — «Аскарово», 1 — «Онгудай»), параметры — непрерывные распределения вокруг
двух наборов §2 (лог-линейная интерполяция по mix + лог-нормальный разброс). Все случайные выбор — из
SeedSequence([corpus_seed, relief_id]); чистая функция, побитно повторяется при OMP_NUM_THREADS=1.
Самодостаточен (формы, поле Фурье, тепловая эрозия — копии из прототипа terrain_stats, чтобы хеш версии отвечал за всё).
"""
import hashlib
import os
import sys

import numpy as np
from numba import njit
import fastscapelib as fs

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "gen"))
from air_synth.v1 import corpus_pb2  # noqa: E402

GENERATOR_VERSION = "fs1-" + hashlib.sha256(open(os.path.abspath(__file__), "rb").read()).hexdigest()[:7]

N = 512            # узлов расчёта
DX = 100.0         # м
T_TOTAL = 4.0e6    # лет, одинаково для всего корпуса (равновесие не требуется)
DT = 1.0e5         # лет
M_EXP, N_EXP = 0.45, 1.0
TAN_CRIT = float(np.tan(np.radians(35.0)))
THERMAL_PASSES = 5
NOISE = 2.0


@njit(cache=True)
def _thermal(z, dx, Sc, npass):
    """Тепловая эрозия: пока уклон между соседями > Sc, 1/8 избытка переносится вниз (массу сохраняет); границы фиксированы."""
    n, m = z.shape
    for _ in range(npass):
        for i in range(n):
            for j in range(m):
                for di in (-1, 0, 1):
                    for dj in (-1, 0, 1):
                        if di == 0 and dj == 0:
                            continue
                        ii = i + di
                        jj = j + dj
                        if ii < 0 or jj < 0 or ii >= n or jj >= m:
                            continue
                        d = dx * (1.41421356 if (di != 0 and dj != 0) else 1.0)
                        ex = z[i, j] - z[ii, jj] - Sc * d
                        if ex > 0:
                            t = 0.125 * ex
                            if not (i == 0 or j == 0 or i == n - 1 or j == m - 1):
                                z[i, j] -= t
                            if not (ii == 0 or jj == 0 or ii == n - 1 or jj == m - 1):
                                z[ii, jj] += t


def _field(n, beta, rng, strike, stretch):
    """Гауссово поле, спектр профиля ~ k^-beta, std = 1. stretch ≥ 1 — вытянутость вдоль простирания
    (волновые числа вдоль strike подавлены в stretch раз: |k|² = (stretch·k_par)² + k_perp²). Углы — как у форм (от +x)."""
    k = np.fft.fftfreq(n)
    KX, KY = np.meshgrid(k, k)             # axis 1 — x (восток), axis 0 — y (север)
    c, s = np.cos(strike), np.sin(strike)
    kpar = KX * c + KY * s
    kperp = -KX * s + KY * c
    K = np.sqrt((stretch * kpar) ** 2 + kperp ** 2)
    K[0, 0] = 1
    amp = K ** (-(beta + 1) / 2.0)
    amp[0, 0] = 0
    f = np.fft.ifft2(amp * np.fft.fft2(rng.standard_normal((n, n)))).real
    return (f - f.mean()) / f.std()


def _ridge(f, X, Y):
    """Гребень (прототип forms.ridge), X, Y в км. f — Form."""
    c, s = np.cos(f.theta_rad), np.sin(f.theta_rad)
    u = (X - f.x_m / 1000) * c + (Y - f.y_m / 1000) * s
    v = -(X - f.x_m / 1000) * s + (Y - f.y_m / 1000) * c
    s1 = f.sigma_m / 1000
    s2 = f.sigma2_m / 1000
    sg = np.where(v > 0, s1, s2)
    L, w = f.length_m / 1000, f.edge
    S = 0.5 * (np.tanh((u + L) / w) - np.tanh((u - L) / w))
    return f.height * np.exp(-0.5 * (v / sg) ** 2) * S


def _blob(f, X, Y):
    c, s = np.cos(f.theta_rad), np.sin(f.theta_rad)
    u = (X - f.x_m / 1000) * c + (Y - f.y_m / 1000) * s
    v = -(X - f.x_m / 1000) * s + (Y - f.y_m / 1000) * c
    return f.height * np.exp(-0.5 * ((u / (f.sigma_m / 1000)) ** 2 + (v / (f.sigma2_m / 1000)) ** 2))


# настраиваемые параметры θ (Professor): имя -> (lo, hi, default); default — середина встроенного распределения mix=0,5
TUNABLE = {
    "uplift_max_m_per_yr": (1e-4, 1.2e-3, 3.7e-4),
    "k0": (2e-6, 1.6e-5, 5.7e-6),
    "diffusion_m2_per_yr": (0.01, 0.1, 0.03),
    "m_exp": (0.3, 0.6, 0.45),
    "k_logsd": (0.5, 1.8, 1.2),
    "fourier_amp": (0.1, 0.8, 0.35),
    "anisotropy": (0.0, 5.0, 1.7),
    "tan_crit": (0.5, 0.9, TAN_CRIT),
    "t_total_yr": (2e6, 8e6, T_TOTAL),
}


def _apply_theta(p, theta):
    for k, v in theta.items():
        if k not in TUNABLE:
            raise KeyError("неизвестный параметр theta: " + k)
        lo, hi, _ = TUNABLE[k]
        v = float(min(max(v, lo), hi))
        if k == "anisotropy":
            p.extra["stretch"] = 1.0 + v
        setattr(p, k, v)
    return p


def _lerp(a, b, t):
    return a + (b - a) * t


def _loglerp(a, b, t):
    return float(np.exp(_lerp(np.log(a), np.log(b), t)))


def sample_params(rng):
    """Все случайные выборы. Возвращает GenParams (mix и т. д.); дополнительные ручки — в extra."""
    p = corpus_pb2.GenParams()
    a = float(rng.beta(0.8, 0.8))                      # mix: почти равномерно, чуть больше у концов
    p.mix = a
    p.n_compute, p.dx_compute_m = N, DX
    ex = p.extra
    p.uplift_max_m_per_yr = _loglerp(2e-4, 7e-4, a) * float(np.exp(0.2 * rng.standard_normal()))
    p.uplift_floor = 0.1
    p.fourier_amp = _lerp(0.3, 0.4, a) * float(np.exp(0.25 * rng.standard_normal()))
    p.fourier_beta = float(rng.uniform(1.6, 2.2))
    p.strike_rad = float(rng.uniform(0, np.pi))
    # вытянутость: 1 + stretch_amp; у Урала сильнее (анизотропия тензора 0,4-0,6), у Онгудая слабее (0,05-0,3)
    ex["stretch"] = float(1.0 + _lerp(3.0, 0.4, a) * rng.uniform(0.4, 1.6))
    p.anisotropy = ex["stretch"] - 1.0
    p.k0 = _loglerp(4e-6, 8e-6, a) * float(np.exp(0.15 * rng.standard_normal()))
    p.k_logsd = float(rng.uniform(1.0, 1.4))
    p.k_beta = float(rng.uniform(1.2, 2.0))
    p.m_exp, p.n_exp = M_EXP, N_EXP
    p.diffusion_m2_per_yr = float(0.03 * np.exp(0.25 * rng.standard_normal()))
    p.tan_crit = TAN_CRIT
    p.thermal_passes = THERMAL_PASSES
    p.t_total_yr, p.dt_yr, p.noise_m = T_TOTAL, DT, NOISE
    p.base_elevation_m = float(max(150.0, _lerp(500.0, 1000.0, a) + 150.0 * rng.standard_normal()))
    # формы: гребни по простиранию и пупыри
    n_r = max(1, int(round(_lerp(2.0, 3.0, a) + rng.uniform(-1, 1))))
    n_b = max(2, int(round(_lerp(12.0, 20.0, a) * np.exp(0.25 * rng.standard_normal()))))
    spread = np.radians(_lerp(10.0, 40.0, a))
    pos = 8.0
    c = 0.5 * N * DX / 1000.0
    for _ in range(n_r):
        f = p.forms.add()
        f.kind = corpus_pb2.Form.RIDGE
        f.theta_rad = float(rng.normal(p.strike_rad, spread))
        f.height = float(rng.uniform(0.5, 1.0))
        f.x_m = 1000 * (c + float(rng.normal(0, pos)))
        f.y_m = 1000 * (c + float(rng.normal(0, pos)))
        sg = float(rng.uniform(*(_lerp(4, 3, a), _lerp(8, 6, a))))
        asym = float(rng.uniform(-0.3, 0.3))
        f.sigma_m = 1000 * sg * float(np.exp(asym))
        f.sigma2_m = 1000 * sg * float(np.exp(-asym))
        f.asym = asym
        f.length_m = 1000 * float(rng.uniform(_lerp(15, 10, a), _lerp(30, 25, a)))
        f.edge = float(rng.uniform(1.5, 4.0))
    for _ in range(n_b):
        f = p.forms.add()
        f.kind = corpus_pb2.Form.BLOB
        s = float(rng.uniform(1.2, 3.5))
        f.x_m = 1000 * (c + float(rng.normal(0, pos)))
        f.y_m = 1000 * (c + float(rng.normal(0, pos)))
        f.theta_rad = float(rng.uniform(0, np.pi))
        f.height = float(rng.uniform(0.1, _lerp(0.4, 0.5, a)))
        f.sigma_m = 1000 * s
        f.sigma2_m = 1000 * s * float(rng.uniform(0.6, 1.0))
    ex["n_ridges"], ex["n_blobs"] = float(n_r), float(n_b)
    return p


def _uplift(p, rng):
    """Безразмерное поле поднятия (max = 1): формы + анизотропное гауссово поле."""
    y, x = np.mgrid[0:N, 0:N] * DX / 1000.0
    u = np.zeros((N, N))
    for f in p.forms:
        u += _ridge(f, x, y) if f.kind == corpus_pb2.Form.RIDGE else _blob(f, x, y)
    u = u + p.fourier_amp * _field(N, p.fourier_beta, rng, p.strike_rad, p.extra["stretch"])
    u = u - u.min()
    return u / u.max()


def generate(corpus_seed, relief_id, theta=None):
    """S3 v2: (GenParams, z100 float64 (384, 384) — м над морем; [j — север, i — восток]). theta — словарь настраиваемых
    параметров из TUNABLE (значения обрезаются по пределам); None — встроенное распределение. Поток ГСЧ от theta не зависит."""
    rng = np.random.default_rng(np.random.SeedSequence([int(corpus_seed), int(relief_id)]))
    p = sample_params(rng)
    if theta:
        _apply_theta(p, theta)
    U = p.uplift_max_m_per_yr * (p.uplift_floor + (1 - p.uplift_floor) * _uplift(p, rng))
    z = rng.uniform(0, p.noise_m, (N, N))
    K = p.k0 * np.exp(p.k_logsd * _field(N, p.k_beta, rng, p.strike_rad, p.extra["stretch"]))
    grid = fs.RasterGrid([N, N], [DX, DX], fs.NodeStatus.FIXED_VALUE)
    graph = fs.FlowGraph(grid, [fs.SingleFlowRouter(), fs.MSTSinkResolver()])
    spl = fs.SPLEroder(graph, K, p.m_exp, p.n_exp, 1e-5)
    diff = fs.DiffusionADIEroder(grid, p.diffusion_m2_per_yr)
    dt = p.dt_yr
    z[0, :] = z[-1, :] = z[:, 0] = z[:, -1] = 0.0
    for _ in range(int(round(p.t_total_yr / dt))):
        graph.update_routes(z)
        A = graph.accumulate(1.0)
        er = spl.erode(z, A, dt)
        zn = z + U * dt - er
        zn -= diff.erode(zn, dt)
        zn[0, :] = zn[-1, :] = zn[:, 0] = zn[:, -1] = 0.0
        z = np.ascontiguousarray(zn)
        _thermal(z, DX, p.tan_crit, p.thermal_passes)
    c0 = (N - 384) // 2
    z100 = z[c0:c0 + 384, c0:c0 + 384].astype(np.float64) + p.base_elevation_m
    return p, z100
