"""4 рельефа прототипа Fastscape (terrain_stats/fastscape_gen.py, TYPES askarovo и ongudai, зёрна 0 и 1) -> proto_reliefs.npz.
Запуск (venv terrain_stats, fastscapelib+numba): OMP_NUM_THREADS=1 <venv>/bin/python gen_proto_reliefs.py
z100 — (384, 384) float32, оси [j север, i восток], высота над уровнем эрозии (min ~ 0), без базы."""
import os, sys
import numpy as np
from multiprocessing import Pool
TS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "terrain_stats")
sys.path.insert(0, TS)
import fastscape_gen as g, run_fastscape as R

def one(a):
    t, s = a
    r = g.gen(R.TYPES[t], s)
    return f"{t}_{s}", r["z100"].astype(np.float32), r["seconds"]

if __name__ == "__main__":
    jobs = [(t, s) for t in ("askarovo", "ongudai") for s in (0, 1)]
    with Pool(4) as p:
        res = p.map(one, jobs)
    np.savez_compressed(os.path.join(os.path.dirname(os.path.abspath(__file__)), "proto_reliefs.npz"),
                        names=np.array([r[0] for r in res]), z100=np.stack([r[1] for r in res]),
                        seconds=np.array([r[2] for r in res]))
    print([(r[0], round(r[2]), float(r[1].min()), float(r[1].max())) for r in res])
