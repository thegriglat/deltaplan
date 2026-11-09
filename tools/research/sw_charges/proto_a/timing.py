"""Замер времени вычисления скоростей: RawKernel против блочного CuPy; масштаб по N; наивный broadcast N×N."""
import json, time
import numpy as np, cupy as cp
from pa_core import Sim, make_images, blocked_cupy

def tm(f, n=5):
    f(); cp.cuda.Device().synchronize()
    t = time.perf_counter()
    for _ in range(n): f()
    cp.cuda.Device().synchronize()
    return (time.perf_counter() - t) / n * 1e3

out = {'gpu': cp.cuda.runtime.getDeviceProperties(0)['name'].decode(), 'rows': []}
rng = np.random.default_rng(0)
for N in (1000, 2500, 5000, 10000, 20000, 40000):
    x = cp.asarray(rng.uniform(0, 3000, N)); z = cp.asarray(rng.uniform(0, 1200, N)); G = cp.asarray(rng.standard_normal(N) * 0.01)
    sab = cp.ones(N)
    r = {'N': N, 'pairs': N * N}
    sim1 = Sim(3.0, make_images())
    r['raw_free_ms'] = tm(lambda: sim1.eval(x, z, x, z, G, sab))
    sim6 = Sim(3.0, make_images(H=1200., kz=1))
    r['raw_6img_ms'] = tm(lambda: sim6.eval(x, z, x, z, G, sab), 3)
    if N <= 20000:
        r['blocked_cupy_ms'] = tm(lambda: blocked_cupy(x, z, x, z, G, 9.0), 2)
    out['rows'].append(r); print(r, flush=True)
# наивный broadcast N×N, N = 10^4: нужна память
N = 10000
x = cp.asarray(rng.uniform(0, 3000, N)); z = cp.asarray(rng.uniform(0, 1200, N)); G = cp.asarray(rng.standard_normal(N) * 0.01)
free, tot = cp.cuda.runtime.memGetInfo()
need = 8 * N * N * 6  # dx, dz, r2, exp, f, f*dz — одновременно
try:
    dx = x[:, None] - x[None, :]; dz = z[:, None] - z[None, :]; r2 = dx * dx + dz * dz
    r2 = cp.where(r2 < 1e-12, cp.inf, r2); f = G[None, :] * (1 - cp.exp(-r2 / 9.0)) / (2 * np.pi * r2); u = -(f * dz).sum(1)
    out['naive'] = {'N': N, 'ok': True, 'need_GB': need / 1e9, 'free_GB': free / 1e9}
except cp.cuda.memory.OutOfMemoryError as e:
    out['naive'] = {'N': N, 'ok': False, 'need_GB': need / 1e9, 'free_GB': free / 1e9}
json.dump(out, open('out/timing_raw.json', 'w'), indent=1)
print(out['naive'])
