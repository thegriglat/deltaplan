"""Сколько прогонок в раунде (точек-прогонок на клетку) и пропускная способность ядра прогонки
на больших массивах (много линий, как в 3D).

  flock /tmp/heat_ca_gpu.lock ../.venv/bin/python bench_thomas.py  → out/thomas_bench.json
"""
import json, os
import sys, time, numpy as np, cupy as cp
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
res = {"per_round": {}, "ns_per_point": {}}
import adi5, line_poisson
from exp5 import config
# 1) сколько точек-прогонок и элементных операций в раунде
cnt = {"pts": 0, "calls": 0}
orig_t, orig_tp = adi5.thomas, adi5.thomas_parity
def t(xp, a, b, c, d, axis):
    cnt["pts"] += b.size; cnt["calls"] += 1; return orig_t(xp, a, b, c, d, axis)
def tp(xp, a, b, c, d, x, axis, parity):
    cnt["pts"] += b.size // 2; cnt["calls"] += 1; return orig_tp(xp, a, b, c, d, x, axis, parity)
adi5.thomas = t; adi5.thomas_parity = tp; line_poisson.thomas = t; line_poisson.thomas_parity = tp
for cname in ("lines_mg", "lines_adi"):
    for cell in (50.0, 25.0):
        a = adi5.ADI5("s1_sun_one_slope", cell, **config(cname, cell))
        cnt.update(pts=0, calls=0); a.round()
        n = a.m.nx * a.m.nz
        res["per_round"][f"{cname}|{cell:g}"] = dict(points_per_cell=cnt["pts"] / n, calls=cnt["calls"])
        print(cname, cell, "прогонок-точек на клетку за раунд:", round(cnt["pts"] / n, 1), "вызовов:", cnt["calls"])
# 2) пропускная способность прогонки на большом массиве (много линий, как в 3D)
k = adi5._thomas_kernel(cp)
for shape in ((32, 400 * 400), (400 * 32, 400)):
    b = cp.full(shape, 4.0, cp.float32); a_ = cp.full(shape, -1.0, cp.float32); c = a_.copy(); d = cp.ones(shape, cp.float32)
    for axis in (0, 1):
        orig_t(cp, a_, b, c, d, axis); cp.cuda.Device().synchronize()
        t0 = time.perf_counter()
        for _ in range(20): orig_t(cp, a_, b, c, d, axis)
        cp.cuda.Device().synchronize()
        ns = (time.perf_counter()-t0)/20/b.size*1e9
        res["ns_per_point"][f"{shape[0]}x{shape[1]}|axis{axis}"] = ns
        print(shape, "ось", axis, f"{ns:.3f} нс/точку")

json.dump(res, open(os.path.join(HERE, "out", "thomas_bench.json"), "w"), indent=1)
