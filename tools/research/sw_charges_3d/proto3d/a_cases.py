"""Постановки прототипа A: рельеф, точка, тепло."""
import numpy as np
from . import ground, pa3d
from panels3d import bg_uniform, bg_zero
import os

REFS = os.path.join(os.path.dirname(__file__), "..", "out", "refs")
SLOPE_PT = {}


def make_case(name):
    """→ (terrain, point (x, y), wind_to (ex, ey) или None)"""
    if name == "flat":
        return ground.flat_terrain(half=3000, dx=100), (0.0, 0.0), (1.0, 0.0)
    if name.startswith("hill"):
        T = ground.gauss_hill_terrain(H=200.0, s=250.0, half=3000, dx=50)
        if name == "hill_wind":     # наветренный склон, r = s
            return T, (-250.0, 0.0), (1.0, 0.0)
        if name == "hill_lee":
            return T, (250.0, 0.0), (1.0, 0.0)
        if name == "hill_foot":
            return T, (-500.0, 0.0), (1.0, 0.0)
    if name == "perd":
        # наветренный склон гряды Perdigão NE у мачты tse06 (−264, −312), ветер NE-случая: на запад-юго-запад
        T = ground.perdigao_terrain(REFS, "PERD_NE", smooth_m=20.0, crop=2500.0)
        return T, (-264.1, -311.9), (-0.87247213, -0.48866388)
    raise KeyError(name)


def normal_at(g, x, y):
    zx, zy = g.slope(np.array([x]), np.array([y]))
    n = np.array([-zx[0], -zy[0], 1.0])
    return n / np.linalg.norm(n), float(np.hypot(zx[0], zy[0]))


def normal_dist(g, p):
    """Знаковое расстояние от точки p до поверхности панелей по нормали ближайшей панели."""
    d = g.c - p[None]
    k = int(np.argmin((d ** 2).sum(1)))
    return float(((p - g.c[k]) * g.n[k]).sum())
