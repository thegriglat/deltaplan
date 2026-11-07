"""Генератор случаев SW1 (идеальные формы рельефа). Формы — как air-phase (tools/research/air_synth/solver/reliefs.py)."""
import math
import os

import numpy as np

from . import io as swio

SHAPES = ("flat", "hill", "ridge", "step_up", "step_down")


def shape_scale(shape, H, s):
    """Масштаб a по макс. крутизне s (тангенс): hill/ridge a = H·√2·e^(−½)/s; ступени a = H/(2s)."""
    if shape == "flat" or H == 0:
        return None
    if shape in ("hill", "ridge"):
        return H * math.sqrt(2.0) * math.exp(-0.5) / s
    return H / (2.0 * s)


def relief(shape, H, a, x, y=None):
    """Высота земли; x, y — массивы (ny, nx) координат центров, центр формы в 0."""
    if shape == "flat" or H == 0:
        return np.zeros_like(x)
    if shape == "hill":
        z = H * np.exp(-(x / a) ** 2)
        return z * np.exp(-(y / a) ** 2) if y is not None else z
    if shape == "ridge":
        return H * np.exp(-(x / a) ** 2)
    if shape == "step_up":
        return H * (1 + np.tanh(x / a)) / 2
    if shape == "step_down":
        return H * (1 - np.tanh(x / a)) / 2
    raise ValueError(f"форма {shape!r}")


def make_case(name, shape="ridge", dim=1, H=50.0, s=0.2, nx=400, ny=1, dx=50.0, dy=None,
              h0=500.0, b0=0.1, U0=None, V0=0.0, fr=None, cd=0.003, f_cor=0.0,
              theta0=290.0, rho_cp=1206.0, g=9.81, h_min=None, b_min=1e-4, forcing=None,
              bc=("farfield", "farfield", "farfield", "farfield"), sponge=(5000.0, 600.0),
              t_end=7200.0, cfl=0.45, steady_tol=5e-4, avg_from=None, out_every=None,
              q_heat=None, mapping=None):
    """Собирает (meta, arrays) SW1. fr задаёт U0 = fr·√(b0·h0). q_heat — число Вт/м² (всюду) или None."""
    if shape not in SHAPES:
        raise ValueError(f"форма {shape!r}")
    if U0 is None:
        U0 = (fr if fr is not None else 0.0) * math.sqrt(b0 * h0)
    if dim == 1:
        ny, dy = 1, None
    else:
        dy = dx if dy is None else dy
    if forcing is None:
        forcing = "balance"
    if h_min is None:
        h_min = 1e-3 * h0
    a = shape_scale(shape, H, s)
    x0 = -0.5 * nx * dx
    y0 = 0.0 if dim == 1 else -0.5 * ny * dy
    xc = x0 + (np.arange(nx) + 0.5) * dx
    yc = np.zeros(1) if dim == 1 else y0 + (np.arange(ny) + 0.5) * dy
    X, Y = np.meshgrid(xc, yc)
    zb = relief(shape, H, a, X, Y if (dim == 2) else None)
    arrays = {"zb": zb}
    if q_heat:
        arrays["q_heat"] = np.full_like(zb, float(q_heat))
    bcd = dict(zip(("west", "east", "south", "north"), bc))
    if dim == 1:
        bcd["south"] = bcd["north"] = None
    meta = {
        "format": "sw-case", "version": 1, "name": name, "dim": dim,
        "grid": {"nx": nx, "ny": ny, "dx": dx, "dy": dy, "x0": x0, "y0": y0},
        "ref": {"h0": h0, "b0": b0, "U0": U0, "V0": V0},
        "physics": {"cd": cd, "f_cor": f_cor, "theta0": theta0, "rho_cp": rho_cp, "g": g,
                    "h_min": h_min, "b_min": b_min, "forcing": forcing},
        "bc": bcd,
        "sponge": None if sponge is None else {"width_m": sponge[0], "tau_s": sponge[1]},
        "run": {"t_end": t_end, "cfl": cfl, "steady_tol": steady_tol, "avg_from": avg_from, "out_every": out_every},
        "source": {"kind": "ideal", "shape": shape, "s": None if a is None else s,
                   "H": None if a is None else H, "a": a, "ref_case": None},
        "mapping": mapping,
    }
    return meta, arrays


def write_case(out_dir, meta, arrays):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, meta["name"] + ".json")
    swio.write_pair(path, meta, arrays)
    return path
