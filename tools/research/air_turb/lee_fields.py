#!/usr/bin/env python3
"""AM-08: поля масштаба 1 у подветренных стартов базы AM-00 (probe.gd) — для сравнения
возмущений (СКО w, рывки) с полем и без. Эталон AM-01 (`air3d/air.py`, код не меняется):
область 400 м → окно 100 м (64 × 64) с центром на старте, с нагревом и без (w_mech/w_conv), как
`tools/wind_field/aushkul_water_field.py`; плюс вход масштабов 2–3 в meta (как
`air_thermals/make_fields.py`): z_i, gam, u10, wdir и массивы heat, h_bl.

Ветер — как в базе: 20 км/ч (5,56 м/с), с обратной стороны старта (heading + 180°).

  PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
  cd tools/research/air3d
  flock /tmp/heat_ca_gpu.lock $PY ../air_turb/lee_fields.py [--sites altai/sinyukha_west,...] [--hour 13]
Пишет tools/research/air_turb/fields/<loc>_<site>_w100_h<hour>.json|bin (вне git, ~5 МБ).
"""
from __future__ import annotations

import argparse
import math
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
AIR3D = HERE.parent / "air3d"
sys.path.insert(0, str(AIR3D))
sys.path.insert(0, str(HERE.parent / "air_thermals"))

import numpy as np  # noqa: E402
import air as A  # noqa: E402
import real as R  # noqa: E402
import make_fields as MF  # noqa: E402

U10 = 20.0 / 3.6
SITES = ["altai/sinyukha_west", "askarovo/biyagoda_west", "aushkul/aushtau_east"]


def grid_window_at(loc, dx, cx, cy, n=64, top_above=2000.0):
    """Как real.grid_window, но центр — любой старт (real.START знает только два места)."""
    cx = round((cx - 0.5 * n * dx) / 25.0) * 25.0 + 0.5 * n * dx
    cy = round((cy - 0.5 * n * dx) / 25.0) * 25.0 + 0.5 * n * dx
    dz = dx / 2
    x0, y0 = cx - n * dx / 2, cy - n * dx / 2
    hc = R.block_mean(loc, x0, y0, dx, n, n)
    zb = math.floor(hc.min() / dz) * dz - dz
    nz = int(math.ceil((hc.max() + top_above - zb) / dz)); nz += nz % 2
    return A.Grid(dx, n, n, dz, zb, nz, x0, y0), hc


def solve(S):
    S.init_nest() if S.nest is not None else S.init_background()
    st = S.solve(max_outer=3000, verbose=False, tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6)
    print(f"  {S.g.dx:g} м: {st}, {S.outer} итераций", flush=True)
    return st


def window(loc, s, hour, wdir, heat):
    g, hc = R.grid_domain(loc, 400)
    D = R.make(loc, g, hc, R.case(loc, g, hc, hour, U10, wdir, heat=heat))
    solve(D)
    gw, hcw = grid_window_at(loc, 100, s["x"], s["y"])
    W = R.make(loc, gw, hcw, R.case(loc, gw, hcw, hour, U10, wdir, heat=heat), parent=D)
    solve(W)
    W.finalize()
    return W


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sites", default=",".join(SITES))
    ap.add_argument("--hour", type=float, default=13.0)
    a = ap.parse_args()
    MF.OUT = HERE / "fields"
    for key in a.sites.split(","):
        loc, site = key.split("/")
        s = R.location(loc).sites[site]
        wdir = (s["heading"] + 180.0) % 360.0
        t0 = time.perf_counter()
        print(f"{key}: ветер {U10:.2f} м/с с {wdir:g}°, {a.hour:g} ч", flush=True)
        Wh = window(loc, s, a.hour, wdir, True)
        Wn = window(loc, s, a.hour, wdir, False)
        MF.U10, MF.WDIR = U10, wdir
        MF.export(Wh, Wn, f"{loc}_{site}_w100_h{a.hour:g}", dict(level="window100", loc=loc, site=site))
        print(f"  {time.perf_counter() - t0:.1f} с", flush=True)


if __name__ == "__main__":
    main()
