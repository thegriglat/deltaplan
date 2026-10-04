"""Ручные наборы (terrain_statistics.md §5.4: Аскарово, Онгудай), умолчание TUNABLE и настроенные θ (подгонка к среднему места,
tune_summary.json: eigentunes[место].theta) — прогон генератором напрямую (6 зёрен) и χ² к квадратам места (detail + far, σ из tune_summary).
-> out/manual_vs_tuned.json. Запуск: OMP_NUM_THREADS=1 ../corpus/.venv/bin/python manual_vs_tuned.py"""
import json, math, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, "..", "corpus"))
import generator as G, observables as ob  # noqa: E402

OUT = os.path.join(HERE, "out")
MANUAL = {
    "askarovo": dict(uplift_max_m_per_yr=2e-4, k0=4e-6, diffusion_m2_per_yr=0.03, m_exp=0.45, k_logsd=0.7, fourier_amp=0.3,
                     tan_crit=math.tan(math.radians(35)), t_total_yr=4e6),
    "ongudai": dict(uplift_max_m_per_yr=7e-4, k0=8e-6, diffusion_m2_per_yr=0.03, m_exp=0.45, k_logsd=0.7, fourier_amp=0.4,
                    tan_crit=math.tan(math.radians(35)), t_total_yr=4e6),
}
NS = 6


def job(a):
    th, s = a
    return ob.vec(ob.observables(G.generate(8001, 100 + s, th)[1]))


if __name__ == "__main__":
    from multiprocessing import Pool
    S = json.load(open(os.path.join(OUT, "tune_summary.json")))
    ref = json.load(open(os.path.join(OUT, "ref_obs.json")))["squares"]
    sig = np.array([S["sigma"][n] for n in ob.NAMES])
    sets = {}
    for place in MANUAL:
        sets[(place, "manual")] = MANUAL[place]
        sets[(place, "default")] = {k: v[2] for k, v in G.TUNABLE.items()}
        sets[(place, "tuned")] = dict(zip(S["tunable"], S["eigentunes"][place]["theta"]))
    keys = list(sets)
    with Pool(12) as p:
        V = np.array(p.map(job, [(sets[k], s) for k in keys for s in range(NS)])).reshape(len(keys), NS, -1)
    R = {}
    for k, v in zip(keys, V):
        place, kind = k
        m = np.nanmean(v, 0)
        sq = [np.array([r["obs"][n] if r["obs"][n] is not None else np.nan for n in ob.NAMES]) for r in ref
              if r["place"] == place and r["kind"] in ("detail", "far")]
        z2 = np.array([((m - y) / sig) ** 2 for y in sq])                    # (квадраты, наблюдаемые)
        R[f"{place}/{kind}"] = dict(theta=sets[k], gen_mean=m.tolist(), chi2_per_obs_mean=float(np.nanmean(z2)),
                                    chi2_by_obs=dict(zip(ob.NAMES, np.nanmean(z2, 0).tolist())), n_squares=len(sq))
        print(k, "mean chi2 per obs %.2f" % R[f"{place}/{kind}"]["chi2_per_obs_mean"])
    json.dump(R, open(os.path.join(OUT, "manual_vs_tuned.json"), "w"), indent=1)
