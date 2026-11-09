"""Порт нынешнего профиля термика (TB2): rust/dp-air/src/terms/thermal/profile.rs::contribution.

Только w; без облачного подсоса (suck = [0, 0]), без оторвавшегося низа (cut_h = -inf), ph.env = 1.
Оси: x, y — горизонталь, z вверх, земля z = 0 (в Rust y вверх: dh = py - src_y). Только numpy.
"""
from __future__ import annotations

import numpy as np

# ThermalCfg::default (rust/dp-air/src/terms/thermal/cfg.rs), нужные порту поля
DEFAULT_CFG = {
    "ring_sink_factor": 1.6,
    "profile_cutoff_radii": 2.5,
    "radius_min_factor": 0.45,
    "ground_ramp_m": 150.0,
    "top_taper_m": 120.0,
}
ALLEN_NORM = 1.0 / 0.75


def smoothstep(lo: float, hi: float, x):
    """Как life::smoothstep."""
    x = np.asarray(x, dtype=np.float64)
    if abs(lo - hi) < 1e-12:
        return np.where(x < lo, 0.0, 1.0)
    t = np.clip((x - lo) / (hi - lo), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def current_w(p: np.ndarray, *, src=(0.0, 0.0), top: float, R: float, w0: float,
              lean=(0.0, 0.0), drift=(0.0, 0.0), ring: float = -1.0,
              cfg: dict | None = None) -> np.ndarray:
    """w термика (м/с) в точках p формы (..., 3) = [x, y, z]; (...,3) -> (...).

    top — верх столба над землёй (src z = 0), R — радиус у верха, w0 — сила ядра,
    ring < 0 — кольцо опускания × ring_sink_factor, иначе × ring.
    """
    c = dict(DEFAULT_CFG)
    if cfg:
        c.update(cfg)
    p = np.asarray(p, dtype=np.float64)
    px, py, pz = p[..., 0], p[..., 1], p[..., 2]
    dh = pz
    cut = c["profile_cutoff_radii"]
    cut2 = cut * cut
    valid = (dh > 0.0) & (pz < top)
    dhs = np.where(valid, dh, 1.0)
    cx = src[0] + drift[0] + lean[0] * dhs - px
    cy = src[1] + drift[1] + lean[1] * dhs - py
    d2 = cx * cx + cy * cy
    valid &= d2 <= R * R * cut2
    xi = np.minimum(dhs / max(top, 1.0), 1.0)
    rf = np.maximum(c["radius_min_factor"], np.cbrt(xi) * (1.0 - 0.25 * xi) * ALLEN_NORM)
    r = R * rf
    x2 = d2 / (r * r)
    valid &= x2 <= cut2
    vert = np.minimum(1.0, np.cbrt(dhs / c["ground_ramp_m"]))
    top_d = top - pz
    vert = np.where(top_d < c["top_taper_m"], vert * smoothstep(0.0, c["top_taper_m"], top_d), vert)
    g = np.exp(-x2) * (1.0 - x2)
    k = c["ring_sink_factor"] if ring < 0.0 else ring
    g = np.where(g < 0.0, g * k, g)
    return np.where(valid, w0 * vert * g, 0.0)


def allen_core(wstar: float, zl: float):
    """Ядро по Аллену (2006), docs/guide/air-model/thermals.md «Законы»:
    (R верха = 0,0765 z_l, w0 = 1,24 w*, n_A = 8,5/z_l² живых ядер на м²)."""
    return 0.0765 * zl, 1.24 * wstar, 8.5 / (zl * zl)
