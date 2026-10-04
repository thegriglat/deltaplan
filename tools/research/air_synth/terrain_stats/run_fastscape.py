"""Генерация 12 рельефов «типа Аскарово» и «типа Онгудая» схемой Fastscape (SPL) + диффузия + тепловая эрозия;
метрики в out/fastscape_metrics.json, поля 400 м и 100 м — out/fastscape_<тип>.npz.
Запуск: OMP_NUM_THREADS=1 .venv/bin/python run_fastscape.py"""
import json, os, numpy as np
from multiprocessing import Pool
import fastscape_gen as g, compare

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
SC = float(np.tan(np.radians(35)))
BASE = dict(n=512, dx=100.0, m=0.45, n_exp=1.0, T=4e6, dt=5e4, Sc=SC, D=0.03, K_logsd=0.7, K_beta=2.0, U_floor=0.1, noise=2.0)
TYPES = {
    "askarovo": dict(BASE, U0=2e-4, K=4e-6, n_ridges=2, strike_deg=170, strike_spread_deg=10, ridge_H=(0.5, 1), ridge_L_km=(15, 30),
                     ridge_sigma_km=(4, 8), n_blobs=6, blob_sigma_km=(1.5, 4), blob_H=(0.1, 0.4), fourier_amp=0.3),
    "ongudai": dict(BASE, U0=7e-4, K=8e-6, n_ridges=3, strike_deg=70, strike_spread_deg=40, ridge_H=(0.5, 1), ridge_L_km=(10, 25),
                    ridge_sigma_km=(3, 6), n_blobs=12, blob_sigma_km=(1.5, 4), blob_H=(0.1, 0.5), fourier_amp=0.4),
}


def run(a):
    t, seed = a
    r = g.gen(TYPES[t], seed)
    return t, seed, r["seconds"], r["z100"].astype(np.float32), r["z400"].astype(np.float32), r["hist"]


if __name__ == "__main__":
    jobs = [(t, s) for t in TYPES for s in range(12)]
    res = {t: [] for t in TYPES}; z100 = {t: [] for t in TYPES}; z400 = {t: [] for t in TYPES}
    with Pool(12) as pool:
        for t, s, sec, a, b, hist in pool.imap(run, jobs):
            m = compare.metrics(a.astype(float), b.astype(float))
            m["seed"] = s; m["seconds"] = sec; m["hist_tail"] = hist[-3:]
            res[t].append(m); z100[t].append(a); z400[t].append(b)
            print(t, s, f"{sec:.0f}s", [round(float(x), 2) for x in compare.row(m)], flush=True)
    for t in TYPES:
        np.savez_compressed(os.path.join(OUT, f"fastscape_{t}.npz"), z100=np.array(z100[t]), z400=np.array(z400[t]))
    json.dump({"params": {t: {k: (list(v) if isinstance(v, tuple) else v) for k, v in p.items()} for t, p in TYPES.items()}, "metrics": res},
              open(os.path.join(OUT, "fastscape_metrics.json"), "w"), indent=1, default=float)
