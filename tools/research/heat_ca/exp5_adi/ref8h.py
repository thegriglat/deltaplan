#!/usr/bin/env python3
"""Эталон для опыта 5: тот же автомат (копия model.py), 8 ч модельного времени БЕЗ досрочной
остановки (steady_dv = steady_dT = 0 → условие «dv < 0» никогда не выполняется), плюс досчёт до 10 ч —
чтобы видеть, насколько сам эталон ещё «плывёт».

Попутно пишем «кривую сходимости шагов по времени»: поля (центры клеток) каждые 10 мин модели —
потом считаем, после скольких шагов автомат входит в 5 % / 1 % от поля через 8 ч.

  ../.venv/bin/python ref8h.py [сценарий ...]      → out/ref8h/<сценарий>_<клетка>.npz
"""
from __future__ import annotations

import json
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import SCENARIOS, Params, HeatCA  # noqa: E402

OUT = os.path.join(HERE, "out", "ref8h")
NAMES = ["s1_sun_one_slope", "s4_inversion"]
CELLS = [200.0, 100.0, 50.0, 25.0]


def centers(m):
    uc, wc, th = m.centers()
    return uc.astype(np.float32), wc.astype(np.float32), th.astype(np.float32)


def run_one(name, cell):
    pr = Params(cell=cell, t_max=10 * 3600.0, steady_dv=0.0, steady_dT=0.0)
    m = HeatCA(SCENARIOS[name], pr)
    m.capture_graph()
    n8 = int(math.ceil(8 * 3600.0 / m.dt))
    n10 = int(math.ceil(pr.t_max / m.dt))
    snap_every = max(1, int(round(600.0 / m.dt)))
    snaps, snap_steps = [], []
    state8 = None
    t0 = time.perf_counter()
    for n in range(m.steps + 1, n10 + 1):
        m.step()
        if m.steps % snap_every == 0:
            snaps.append(np.stack(centers(m)))
            snap_steps.append(m.steps)
            m.stream.use()
        if m.steps == n8:
            state8 = dict(u=m.to_np(m.u), w=m.to_np(m.w), H=m.to_np(m.H), mu=m.to_np(m.mu), p=m.to_np(m.p),
                          c=np.stack(centers(m)), t=m.t, steps=m.steps)
            m.stream.use()
        if m.steps >= n10:
            break
    m.sync()
    wall = time.perf_counter() - t0
    c10 = np.stack(centers(m))
    b = m.budget()
    os.makedirs(OUT, exist_ok=True)
    meta = dict(scenario=name, cell=cell, dt=m.dt, nx=m.nx, nz=m.nz, steps8=state8["steps"], t8=state8["t"],
                steps10=m.steps, wall_incl_snapshots=wall, m_res=b["m_res"], h_res=b["h_res"], m_anom=b["m_anom"],
                params=pr.__dict__)
    np.savez_compressed(os.path.join(OUT, f"{name}_{cell:g}.npz"),
                        u=state8["u"], w=state8["w"], H=state8["H"], mu=state8["mu"], p=state8["p"],
                        c8=state8["c"], c10=c10, snaps=np.stack(snaps).astype(np.float16), snap_steps=np.array(snap_steps),
                        solid=m.solid_np, xc=m.xc, zc=m.zc, h=m.h, kb=m.kb, q=m.q_np,
                        info=json.dumps(meta, default=float))
    ok = ~m.solid_np

    def rel(a, bb):
        return float(np.linalg.norm((a - bb)[..., ok]) / np.linalg.norm(bb[..., ok]))
    print(f"{name} {cell:g} м: 8 ч = {state8['steps']} шагов; дрейф 8→10 ч: u {rel(c10[0], state8['c'][0]):.3%}, "
          f"w {rel(c10[1], state8['c'][1]):.3%}, θ′ {rel(c10[2], state8['c'][2]):.3%}; {wall:.1f} с", flush=True)


def main():
    names = sys.argv[1:] or NAMES
    for name in names:
        for cell in CELLS:
            run_one(name, cell)


if __name__ == "__main__":
    main()
