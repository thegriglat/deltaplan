#!/usr/bin/env python3
"""Точная неподвижная точка шага автомата — раундами прогонок до «машинного» установления
(невязки ~1e-7), затем ПРОВЕРКА самим автоматом: запускаем шаги по времени с этого состояния на 2 ч
модели и смотрим, насколько поле уходит (должно стоять).

Нужна потому, что эталон «8 ч шагов» сам ещё не установился: за 8→10 ч θ′ меняется ещё на ~0,8 %.

  ../.venv/bin/python fixedpoint.py [сценарий ...]  → out/fixed/<сценарий>_<клетка>.npz, out/fixed/fixed.json
"""
from __future__ import annotations

import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from adi5 import ADI5  # noqa: E402

OUT = os.path.join(HERE, "out", "fixed")
NAMES = ["s1_sun_one_slope", "s4_inversion"]
CELLS = [200.0, 100.0, 50.0, 25.0]
# надёжные (медленные) настройки: Δτ = 100 с, давление — многоуровневые прогонки, 3 прохода на поле
KW = dict(dtau=100.0, dtau_h=100.0, heat_iters=3, mom_iters=3, p_mode="lmg", p_iters=2)


def rel(a, b, ok):
    return float(np.linalg.norm((a - b)[..., ok]) / np.linalg.norm(b[..., ok]))


def solve(name, cell, max_rounds=4000, tol=2e-6):
    a = ADI5(name, cell, **KW)
    a.capture()
    while a.rounds < max_rounds:
        for _ in range(50):
            a.step()
        dm = float(a.dmax)
        a.m.stream.use()
        if dm < tol or not math.isfinite(dm):
            break
    return a


def check_with_automaton(a, hours=2.0):
    """Автомат с начальным состоянием = решение прогонками; дрейф за hours часов."""
    m = a.m
    xp = m.xp
    m.u[...] = a.u
    m.w[...] = a.w
    m.H[...] = (m.tb + a.th) * m.fluidf
    m.mu[...] = 0
    m.p[...] = a.p
    c0 = np.stack(a.centers())
    m.capture_graph()
    n = int(math.ceil(hours * 3600 / m.dt))
    for _ in range(n):
        m.step()
    m.sync()
    c1 = np.stack(m.centers())
    return c0, c1


def main():
    os.makedirs(OUT, exist_ok=True)
    names = sys.argv[1:] or NAMES
    path = os.path.join(OUT, "fixed.json")
    res = json.load(open(path)) if os.path.exists(path) else {}
    for name in names:
        for cell in CELLS:
            a = solve(name, cell)
            Rh, Ru, Rw, D = [a.m.to_np(x) for x in a.residuals()]
            a.m.stream.use()
            c0, c1 = check_with_automaton(a)
            ok = ~a.m.solid_np
            r8 = np.load(os.path.join(HERE, "out", "ref8h", f"{name}_{cell:g}.npz"))
            c8, c10 = r8["c8"], r8["c10"]
            e = dict(rounds=a.rounds, dmax=float(a.dmax),
                     res_heat=float(np.abs(Rh).max()), heat_src_max=float(a.m.heat_src.max()),
                     res_mom=float(max(np.abs(Ru).max(), np.abs(Rw).max())), div_max=float(np.abs(D).max()),
                     drift_2h=[rel(c1[j], c0[j], ok) for j in (1, 0, 2)],
                     fixed_vs_8h=[rel(c8[j], c0[j], ok) for j in (1, 0, 2)],
                     fixed_vs_10h=[rel(c10[j], c0[j], ok) for j in (1, 0, 2)],
                     settings=KW)
            res[f"{name}_{cell:g}"] = e
            np.savez_compressed(os.path.join(OUT, f"{name}_{cell:g}.npz"), c=c0.astype(np.float32),
                                u=a.m.to_np(a.u), w=a.m.to_np(a.w), th=a.m.to_np(a.th), p=a.m.to_np(a.p))
            print(f"{name} {cell:g} м: {a.rounds} раундов, Δ={e['dmax']:.1e}; дрейф автомата за 2 ч с этого "
                  f"состояния (w,u,θ′) = {', '.join(f'{x:.2e}' for x in e['drift_2h'])}; "
                  f"эталон 8 ч от неподвижной точки: {', '.join(f'{x:.2%}' for x in e['fixed_vs_8h'])}; "
                  f"10 ч: {', '.join(f'{x:.2%}' for x in e['fixed_vs_10h'])}", flush=True)
            json.dump(res, open(path, "w"), indent=1)


if __name__ == "__main__":
    main()
