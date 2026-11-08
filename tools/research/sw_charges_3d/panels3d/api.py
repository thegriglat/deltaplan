"""Публичные функции SWD2: assemble, solve, velocity, surface_flow."""
import numpy as np
from . import influence as _inf
from .terrain import u_ref_of


def assemble(panels, backend="auto"):
    """Матрица нормальных скоростей N×N в центроидах (собственный вклад σ/2); факторизация кешируется в объекте."""
    return _inf.assemble(panels, backend)


def solve(panels, bg, extra=None, infl=None, method="dense", backend="auto"):
    """σ (N, м/с): нормальная скорость (фон + extra + панели) в центроидах = 0. → (sigma, info)."""
    return _inf.solve(panels, bg, extra, infl, method, backend)


def velocity(panels, sigma, bg, x, y, z, extra=None, backend="auto"):
    """(u, v, w) в точках; под поверхностью панелей — NaN."""
    return _inf.velocity(panels, sigma, bg, x, y, z, extra, backend)


def surface_flow(panels, sigma, bg, extra=None):
    """{ut (N, 3), speed (N), cp = 1 − (speed/U_ref)², U_ref}."""
    ut = _inf.tangent_velocity(panels, sigma, bg, extra)
    speed = np.linalg.norm(ut, axis=1)
    U_ref, _ = u_ref_of(bg, panels.terrain)
    cp = 1.0 - (speed / U_ref) ** 2 if U_ref > 0 else np.full_like(speed, np.nan)
    return dict(ut=ut, speed=speed, cp=cp, U_ref=U_ref)
