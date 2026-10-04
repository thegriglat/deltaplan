"""Разложение рельефов на формы (жадно). Запуск: .venv/bin/python decompose.py -> out/decomp.json, out/decomp_<место>_*.npz
Задачи: (место, detail400 | detail100 | far400-квадраты) x (формы только положительные | со знаком)."""
import json, os, sys, time
import numpy as np
from multiprocessing import Pool
import dem, forms, stats

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
CHECK = (1, 2, 3, 5, 10, 20, 30)


def job(args):
    place, tag, signed, nforms = args
    if tag == "detail400":
        h = dem.coarsen(dem.load(place, "detail")[0], 16)[2:98, 2:98]; dx = 400.0; step = 1
    elif tag == "detail100":
        h = dem.coarsen(dem.load(place, "detail")[0], 4); dx = 100.0; step = 2
    else:  # far400_i_j
        i, j = int(tag.split("_")[1]), int(tag.split("_")[2])
        hf = dem.coarsen(dem.load(place, "far")[0], 4)
        h = hf[i * 100:(i + 1) * 100, j * 100:(j + 1) * 100][2:98, 2:98]; dx = 400.0; step = 1
    t = time.time()
    fs, curve, model = forms.fit_greedy(h, dx, nforms=nforms, signed=signed, fit_step=step)
    r = dict(place=place, tag=tag, signed=signed, dx=dx, seconds=time.time() - t,
             curve=curve, forms=[forms.describe(f) for f in fs], var=float(h.var()), relief=float(h.max() - h.min()),
             sigma_h=float(h.std()))
    if not tag.startswith("far"):
        np.savez_compressed(os.path.join(OUT, f"decomp_{place}_{tag}_{'s' if signed else 'p'}.npz"), h=h.astype(np.float32),
                            model=model.astype(np.float32))
        P0 = stats.peaks(h, dx); P1 = stats.peaks(model, dx)
        r["recon"] = dict(real_peaks={t_: int((P0["prom"] >= t_).sum()) for t_ in (30, 100, 300)},
                          model_peaks={t_: int((P1["prom"] >= t_).sum()) for t_ in (30, 100, 300)},
                          real_slope=stats.slope_stats(h, dx), model_slope=stats.slope_stats(model, dx),
                          resid_slope=stats.slope_stats(h - model, dx))
    return r


if __name__ == "__main__":
    tasks = []
    for p in dem.PLACES:
        for signed in (False, True):
            tasks.append((p, "detail400", signed, 30))
            tasks.append((p, "detail100", signed, 30))
        for i in range(4):
            for j in range(4):
                tasks.append((p, f"far400_{i}_{j}", False, 20))
    with Pool(18) as pool:
        res = []
        for r in pool.imap_unordered(job, tasks):
            res.append(r); print(r["place"], r["tag"], r["signed"], f"{r['seconds']:.0f}s", flush=True)
    json.dump(res, open(os.path.join(OUT, "decomp.json"), "w"), indent=1, default=float)
