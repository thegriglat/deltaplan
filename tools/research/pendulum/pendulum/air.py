"""Поля воздуха для прототипа (NED, м/с): штиль, термик, замороженная турбулентность, ветер."""

from __future__ import annotations

import math

import numpy as np


def calm(points):
    return np.zeros_like(points)


def uniform(wind_ned):
    w = np.asarray(wind_ned, float)

    def f(points):
        return np.broadcast_to(w, points.shape).copy()

    return f


def thermal(center_xy, w0=3.0, radius=25.0, base=None):
    """Гауссов термик: восходящий поток w0·exp(−r²/R²) (вверх = −z в NED)."""
    cx, cy = center_xy

    def f(points):
        r2 = (points[:, 0] - cx) ** 2 + (points[:, 1] - cy) ** 2
        out = np.zeros_like(points)
        out[:, 2] = -w0 * np.exp(-r2 / radius ** 2)
        if base is not None:
            out += base(points)
        return out

    return f


def turbulence(sigma=1.0, length=40.0, n_modes=256, seed=1, kmin=2 * math.pi / 400, kmax=2 * math.pi / 1.5,
               base=None):
    """Замороженное поле однородной изотропной турбулентности: сумма случайных фурье-мод,
    спектр фон Кармана E(k) ∝ (kL)⁴/(1+(kL)²)^(17/6), бездивергентно (амплитуда ⊥ k),
    σ — СКО каждой составляющей, L — масштаб (≈ 40 м: приземный слой, высота ~100 м)."""
    rng = np.random.default_rng(seed)
    ks = np.exp(np.linspace(math.log(kmin), math.log(kmax), n_modes))
    dk = np.gradient(ks)
    E = (ks * length) ** 4 / (1 + (ks * length) ** 2) ** (17.0 / 6.0)
    amp = np.sqrt(E * dk)
    dirs = rng.normal(size=(n_modes, 3))
    dirs /= np.linalg.norm(dirs, axis=1, keepdims=True)
    a = rng.normal(size=(n_modes, 3))
    a -= (a * dirs).sum(1, keepdims=True) * dirs
    a /= np.linalg.norm(a, axis=1, keepdims=True)
    phase = rng.uniform(0, 2 * math.pi, n_modes)
    K = dirs * ks[:, None]
    A = a * amp[:, None]
    # нормировка на σ: средний квадрат составляющей = Σ|A|²/2 /3·... считаем численно
    var = (A ** 2).sum(0) / 2.0
    A *= sigma / math.sqrt(var.mean())

    def f(points):
        ph = points @ K.T + phase[None]
        out = np.cos(ph) @ A
        if base is not None:
            out += base(points)
        return out

    return f
