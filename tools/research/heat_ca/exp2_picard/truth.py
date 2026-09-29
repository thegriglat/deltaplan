#!/usr/bin/env python3
"""«Истинная» неподвижная точка автомата: тот же автомат (копия model.py), но досчитанный с
критерием установления в 10 раз строже (Δv < 0,002 м/с и Δθ < 0,003 К за 10 мин), до 12 ч.

Зачем: эталон out/refs остановлен по мягкому критерию (0,02 м/с / 0,03 К за 10 мин) и сам ещё
чуть «плывёт». Итерации Пикара сходятся к точной неподвижной точке — сравниваем и с эталоном,
и с ней, чтобы разделить «ошибку схемы» и «недосчитанность эталона».

  ../.venv/bin/python truth.py [сценарий ...]  → out/truth/<сценарий>_<клетка>.npz
"""
from __future__ import annotations

import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import SCENARIOS, Params, run  # noqa: E402

OUT = os.path.join(HERE, "out", "truth")
NAMES = ["s1_sun_one_slope", "s2_both_slopes", "s3_wind", "s4_inversion"]
CELLS = [200.0, 100.0, 50.0, 25.0]


def main():
    os.makedirs(OUT, exist_ok=True)
    names = sys.argv[1:] or NAMES
    for name in names:
        for cell in CELLS:
            pr = Params(cell=cell, t_max=12 * 3600.0, steady_dv=0.002, steady_dT=0.003)
            model, _, series, info = run(SCENARIOS[name], pr, record=False, verbose=False)
            uc, wc, th = model.centers()
            meta = dict(scenario=name, cell=cell, steady_step=info["steady_step"], steady_t=info["steady_t"],
                        steady_wall=info["steady_wall"], steps=info["steps"], dt=info["dt"])
            np.savez_compressed(os.path.join(OUT, f"{name}_{cell:g}.npz"), uc=uc, wc=wc, th=th,
                                u=model.to_np(model.u), w=model.to_np(model.w),
                                thp=model.to_np(model.theta() - model.tb), p=model.to_np(model.p),
                                info=json.dumps(meta, default=float))
            print(f"{name} {cell:g} м: строгое установление {info['steady_step']} шагов "
                  f"({(info['steady_t'] or 0)/3600:.1f} ч), всего {info['steps']}", flush=True)


if __name__ == "__main__":
    main()
