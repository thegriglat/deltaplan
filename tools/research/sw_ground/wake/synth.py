"""Синтетический хребет Аньези (H/L = 0,5) для проверок следа: сетка, решение, поле до/после."""
from __future__ import annotations

import math
from types import SimpleNamespace

import numpy as np

from ground import model as M  # noqa: F401
import core as C  # noqa: E402  (compare/core.py: bg_log)
import panels3d as P

from . import core as W


def agnesi_run(H=125.0, a=250.0, ds_min=25.0, z0=0.1, focus_x=None, hx=3000.0, hy=2500.0, step=25.0, backend="auto"):
    """Хребет z = H/(1 + (x/a)²) вдоль y (ветер +x), лог-фон как SWD5. → SimpleNamespace(panels, sigma, bg, infl, z0)."""
    x = np.arange(-hx, hx + 0.1, step)
    y = np.arange(-hy, hy + 0.1, step)
    X, _ = np.meshgrid(x, y)
    t = P.Terrain3D(x, y, H / (1 + (X / a) ** 2), far_m=10000.0)
    if focus_x is None:
        focus_x = np.arange(-1000.0, 1501.0, 100.0)
    foc = [(float(xx), 0.0) for xx in focus_x]
    p = P.build_panels(t, focus=foc, ds_min=ds_min, focus_r=4 * ds_min, ds_max=800.0, growth=1.3)
    bg = C.bg_log(C.U10, z0, C.Z_SAT, t, (1.0, 0.0), smooth_m=250.0)
    infl = P.assemble(p, backend)
    s, _ = P.solve(p, bg, None, infl)
    return SimpleNamespace(panels=p, sigma=s, bg=bg, infl=infl, z0=z0, terrain=t, H=H, a=a)


def line_speeds(run, sig_w, xs, zagl):
    xs = np.asarray(xs, float)
    y = np.zeros_like(xs)
    z = run.panels.height(xs, y) + zagl
    pj = M.jh_parts(run, xs, y, z)
    pw = W.wake_parts(run, xs, y, z, sig_w)
    return pj, pw
