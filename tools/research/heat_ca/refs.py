#!/usr/bin/env python3
"""Эталонные установившиеся поля (шаги по времени) для опытов «слои как матрицы».

  .venv/bin/python refs.py            # 4 сценария × 200/100/50/25 м → out/refs/<сценарий>_<клетка>.npz

В файле: uc, wc (м/с, центры клеток; NaN под землёй), th (θ′, К), solid (маска), xc, zc, h (рельеф),
kb (первая воздушная клетка столбца), q (нагрев, К·м/с), info (json: шагов до установления, время
до установления на GPU, мс/шаг, dt, сетка). Опыты читают эти файлы, сами эталон не пересчитывают.
"""
from __future__ import annotations

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import SCENARIOS, Params, run  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out", "refs")
NAMES = ["s1_sun_one_slope", "s2_both_slopes", "s3_wind", "s4_inversion"]
CELLS = [200.0, 100.0, 50.0, 25.0]


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in NAMES:
        for cell in CELLS:
            model, _, series, info = run(SCENARIOS[name], Params(cell=cell, t_max=6 * 3600.0), record=False,
                                         verbose=False)
            uc, wc, th = model.centers()
            meta = dict(scenario=name, cell=cell, nx=model.nx, nz=model.nz, dt=info["dt"],
                        steady_step=info["steady_step"], steady_t=info["steady_t"], steady_wall=info["steady_wall"],
                        ms_step=info["wall"] / info["steps"] * 1e3, params=info["params"],
                        m_res=series[-1]["m_res"], h_res=series[-1]["h_res"])
            np.savez_compressed(os.path.join(OUT, f"{name}_{cell:g}.npz"), uc=uc, wc=wc, th=th,
                                solid=model.solid_np, xc=model.xc, zc=model.zc, h=model.h, kb=model.kb,
                                q=model.q_np, info=json.dumps(meta, default=float))
            print(f"{name} {cell:g} м: установление {info['steady_step']} шагов, {info['steady_wall']} с")


if __name__ == "__main__":
    main()
