"""Земля для SWD-12: рельеф (синтетика или растр случая) → panels3d, решение с произвольной внешней скоростью."""
import time
import numpy as np
import h5py
import cupy as cp
from panels3d import Terrain3D, build_panels, assemble, solve, bg_uniform, bg_zero
from panels3d import influence as inf
from . import vp

REFS = None


def flat_terrain(half=4000.0, dx=200.0, z0=0.0):
    x = np.arange(-half, half + dx / 2, dx)
    return Terrain3D(x, x.copy(), np.full((x.size, x.size), z0), far_m=half, blend_m=0.0)


def gauss_hill_terrain(H=200.0, s=250.0, half=4000.0, dx=50.0):
    x = np.arange(-half, half + dx / 2, dx)
    X, Y = np.meshgrid(x, x)
    return Terrain3D(x, x.copy(), H * np.exp(-(X ** 2 + Y ** 2) / (2 * s ** 2)), far_m=half, blend_m=0.0)


def perdigao_terrain(refs_dir, case="PERD_NE", smooth_m=20.0, crop=2000.0, center=(0.0, 0.0)):
    """Растр terrain из SWD1 (GLO-30 DSM 10 м; крона вычтена как смещение 0,7·h_c·доля леса — как perdigao.py);
    `smooth_m` — гауссово сглаживание остатка DSM; обрезка квадратом ±crop около center."""
    with h5py.File(f"{refs_dir}/{case}.h5", "r") as f:
        g = f["terrain"]
        x, y, z = g["x"][:], g["y"][:], g["z"][:]
    ix = np.where(np.abs(x - center[0]) <= crop)[0]
    iy = np.where(np.abs(y - center[1]) <= crop)[0]
    return Terrain3D(x[ix[0]:ix[-1] + 1], y[iy[0]:iy[-1] + 1], z[iy[0]:iy[-1] + 1, ix[0]:ix[-1] + 1],
                     smooth_m=smooth_m, far_m=crop, blend_m=500.0)


class Ground:
    """Панели + LU один раз; `solve_sigma(bg, X, A, SG)` — σ для фона и вихревых частиц; `speed(...)`."""

    def __init__(self, terrain, focus, ds_min=30.0, ds_max=600.0, growth=1.2, focus_r=None):
        t0 = time.time()
        self.terrain = terrain
        self.panels = build_panels(terrain, focus=focus, ds_min=ds_min, ds_max=ds_max, growth=growth,
                                   focus_r=focus_r)
        self.infl = assemble(self.panels, "cupy")
        self.infl.lu()
        self.N = self.panels.N
        self.t_build = time.time() - t0
        self.c = self.panels.c
        self.n = self.panels.n

    def solve_sigma(self, bg, X=None, A=None, SG=None, shifts=None):
        extra = None
        if X is not None and len(X):
            def extra(x, y, z):
                P = np.stack([x, y, z], 1)
                u = vp.velocity(P, X, A, SG, shifts=shifts).get()
                return u[:, 0], u[:, 1], u[:, 2]
        sigma, info = solve(self.panels, bg, extra=extra, infl=self.infl, method="dense", backend="cupy")
        return sigma

    def panel_vel(self, sigma, P):
        return inf.panel_velocity(self.panels, sigma, P, backend="cupy")

    def height(self, x, y):
        return self.panels.height(x, y)

    def slope(self, x, y, h=10.0):
        zx = (self.height(x + h, y) - self.height(x - h, y)) / (2 * h)
        zy = (self.height(x, y + h) - self.height(x, y - h)) / (2 * h)
        return zx, zy
