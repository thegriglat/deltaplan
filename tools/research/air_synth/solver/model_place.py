"""S4 v1: модельный рельеф (g100) -> место для решателя P2 (tools/research/air3d, код не правится).

Место устроено как places.TerrainLocation/SynthLocation: h (384 x 384, float64, оси [j север, i восток]), info
spacing = 100 м, x0 = y0 = -19200 м, water = None, sites = {} (стартов нет), height_at (билинейно, как у синтетики),
контекст — условные широта/долгота (Онгудай, июль; как синтетика), ground_context по рельефу.
Решатель берёт высоты клеток 400 м как блочное среднее 4 x 4 клеток g100 (R.grid_domain -> terrain.block_mean) =
g400 корпуса S1 (блочное среднее до квантования).

Подключение: register(name, g100, base_m) подменяет R.location/R.context так, что имя `name` ведёт на модельное
место, остальные — как у пилота (places.location/context).
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
PILOT = ROOT / "tools/research/air_nn_pilot"
AIR3D = ROOT / "tools/research/air3d"
for p in (str(PILOT), str(AIR3D)):
    if p not in sys.path:
        sys.path.insert(0, p)

import places as P      # noqa: E402  (подменяет real.location/context; ниже подменяем ещё раз)
import real as R        # noqa: E402
import weather as W     # noqa: E402

N100, DX100, X0 = 384, 100.0, -19200.0
_REG: dict[str, "ModelLocation"] = {}


class ModelLocation:
    def __init__(self, name, g100, base_m=0.0):
        g100 = np.asarray(g100, dtype=np.float64)
        assert g100.shape == (N100, N100), g100.shape
        assert np.all(np.isfinite(g100))
        self.id = name
        self.h = g100 + float(base_m)
        self.info = dict(spacing=DX100, x0=X0, y0=X0)
        self.water = None
        self.meta = dict(center_lat=None, center_lon=None)
        self.sites = {}

    def height_at(self, x, z):
        y = -z
        s = DX100
        fi = (x - X0) / s - 0.5   # узлы билинейной интерполяции — центры клеток
        fj = (y - X0) / s - 0.5
        i0 = int(np.clip(np.floor(fi), 0, N100 - 2)); j0 = int(np.clip(np.floor(fj), 0, N100 - 2))
        a, b = min(max(fi - i0, 0.0), 1.0), min(max(fj - j0, 0.0), 1.0)
        h = self.h
        return float((1 - b) * ((1 - a) * h[j0, i0] + a * h[j0, i0 + 1]) + b * ((1 - a) * h[j0 + 1, i0] + a * h[j0 + 1, i0 + 1]))


def _context(loc):
    L = _REG[loc]
    ref = json.loads((ROOT / "configs/locations/ongudai.json").read_text())
    rc = W.CFG["reference_context"]
    ctx = dict(month=rc["month"], day=rc["day"], lat=ref["center_lat"], lon=ref["center_lon"],
               utc_offset_h=ref.get("utc_offset_h", round(ref["center_lon"] / 15.0)))
    ctx.update(W.ground_context(L.height_at))
    return ctx


_CTX: dict[str, dict] = {}


def location(loc):
    return _REG[loc] if loc in _REG else P.location(loc)


def context(loc):
    if loc in _REG:
        if loc not in _CTX:
            _CTX[loc] = _context(loc)
        return _CTX[loc]
    return P.context(loc)


def register(name, g100, base_m=0.0):
    L = ModelLocation(name, g100, base_m)
    _REG[name] = L
    _CTX.pop(name, None)
    R.location = location
    R.context = context
    return L


def solver_version():
    """s0-<7 знаков sha1> от air3d/*.py (как air_nn_pilot/dataset.py)."""
    import hashlib
    h = hashlib.sha1()
    for p in sorted(AIR3D.glob("*.py")):
        h.update(p.name.encode() + b"\0" + p.read_bytes() + b"\0")
    return "s0-" + h.hexdigest()[:7]
