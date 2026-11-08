"""Время шага на свободном GPU без диагностики: частицы + панели. Выход out/step3/timing_raw.json (и в results.json через collect)."""
import json, os, sys, time
import numpy as np, cupy as cp
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, '..'))
import panels2d as P2
from step3_core import Ground, Run, patch_state
import step3_terrain as TT

ag = TT.agnesi()
out = []
for ds in (25.0, 50.0):
    gr = Ground(ag, ds_min=ds)
    for N in (2500, 5000, 10000):
        for k in (1, 4):
            st, meta = patch_state(-289.0, 280.0, 100.0, 1.0, N)
            run = Run(gr, P2.bg_uniform(2.5), meta['sigma'], resolve_every=k)
            for _ in range(3): run.step(st, 1.0)
            cp.cuda.Device().synchronize()
            run.t_solve = run.t_vel = 0.0
            t0 = time.time()
            n = 20
            for _ in range(n): run.step(st, 1.0)
            cp.cuda.Device().synchronize()
            dt = (time.time() - t0) / n
            out.append(dict(ds_min=ds, n_panels=int(gr.p.n), N=int(st['x'].size), k=k, ms_per_step=1e3 * dt,
                            ms_solve=1e3 * run.t_solve / n, ms_vel=1e3 * run.t_vel / n, matrix_inverse_s=gr.t_setup))
            print(out[-1], flush=True)
json.dump(out, open(os.path.join(HERE, 'out', 'step3', 'timing_raw.json'), 'w'), indent=1)
