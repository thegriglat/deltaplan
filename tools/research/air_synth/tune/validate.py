"""Проверка: 8 точек облака (по одной на разные квадраты) прогнать генератором напрямую (3 зерна) и сравнить наблюдаемые
с реальным квадратом и с предсказанием полинома. -> out/validate.json. Запуск: OMP_NUM_THREADS=1 ../corpus/.venv/bin/python validate.py"""
import json, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, "..", "corpus"))
import generator as G, observables as ob  # noqa: E402

OUT = os.path.join(HERE, "out")


def job(a):
    th, s = a
    return ob.vec(ob.observables(G.generate(7001, 900 + s, th)[1]))


if __name__ == "__main__":
    from multiprocessing import Pool
    cloud = json.load(open(os.path.join(OUT, "theta_cloud.json")))
    S = json.load(open(os.path.join(OUT, "tune_summary.json")))
    sqs = json.load(open(os.path.join(OUT, "ref_obs.json")))["squares"] + json.load(open(os.path.join(OUT, "ref_obs_pool.json")))["squares"]
    ref = {r["name"]: r for r in sqs}
    meta = json.load(open(os.path.join(OUT, "theta_cloud_meta.json")))
    names = meta["squares"]
    idx = np.linspace(0, len(names) - 1, 8).astype(int)
    tasks = [(dict(zip(cloud["names"], cloud["points"][i])), s) for i in idx for s in range(3)]
    with Pool(12) as p:
        V = np.array(p.map(job, tasks)).reshape(len(idx), 3, -1)
    sig = np.array([S["sigma"][n] for n in ob.NAMES]); sgen = np.array([S["sigma_gen"][n] for n in ob.NAMES])
    res = []
    for k, i in enumerate(idx):
        y = np.array([ref[names[i]]["obs"][n] if ref[names[i]]["obs"][n] is not None else np.nan for n in ob.NAMES])
        m = np.nanmean(V[k], 0)
        poly = np.array(meta["poly"][i])
        res.append(dict(square=names[i], gen_mean=m.tolist(), ref=y.tolist(), poly=poly.tolist(), z_vs_ref=((m - y) / sig).tolist(),
                        z_vs_poly_rms=float(np.sqrt(np.nanmean(((m - poly) / sig) ** 2))),
                        z_vs_poly_gen_noise_rms=float(np.sqrt(np.nanmean(((m - poly) / (sgen / np.sqrt(3) + 1e-9)) ** 2))),
                        z_vs_ref_rms=float(np.sqrt(np.nanmean(((m - y) / sig) ** 2)))))
        print(names[i], "rms z vs ref %.2f, vs poly %.2f" % (res[-1]["z_vs_ref_rms"], res[-1]["z_vs_poly_rms"]))
    json.dump(dict(names=ob.NAMES, items=res), open(os.path.join(OUT, "validate.json"), "w"), indent=1)
