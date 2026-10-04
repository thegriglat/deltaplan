"""Генерация «по замеренным статистикам» суммой форм: параметры форм — бутстрэп из форм, найденных жадным разложением
16 квадратов far (400 м) того же места (out/decomp.json); положения — равномерно по области; шероховатость — гауссово поле
с β=2,7 и СКО = медианный остаток разложения. 12 рельефов 96x96 (400 м) на тип -> out/forms_gen_<тип>.npz, out/forms_gen_metrics.json"""
import json, os, numpy as np
import dem, forms, stats, fastscape_gen as g

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
NFORMS = 20


def pool_for(place):
    D = json.load(open(os.path.join(OUT, "decomp.json")))
    sel = [d for d in D if d["place"] == place and d["tag"].startswith("far400")]
    fl = [f for d in sel for f in d["forms"]]
    resid = float(np.median([d["curve"][-1][1] for d in sel]))
    return fl, resid


def make(place_pool, resid, rng, ext_km=38.4, n=96):
    fl = place_pool
    y, x = np.mgrid[0:n, 0:n] * 0.4
    z = np.zeros((n, n))
    for _ in range(NFORMS):
        f = fl[rng.integers(len(fl))]
        th = np.radians(f["theta_deg"])
        if f["kind"] == "ridge":
            p = [rng.uniform(0, ext_km), rng.uniform(0, ext_km), th, f["H_m"], np.log(f["sigma_km"]), np.log(f["L_half_km"]),
                 np.log(f["w_km"]), f["asym"]]
            z += forms.ridge(p, x, y)
        else:
            p = [rng.uniform(0, ext_km), rng.uniform(0, ext_km), th, f["H_m"], np.log(f["sigma1_km"]), np.log(f["sigma2_km"])]
            z += forms.blob(p, x, y)
    z += resid * g.fourier_field(n, 2.7, rng)
    return z - z.min()


def metrics400(z):
    f = (40.0 / 38.4) ** 2
    P = stats.peaks(z, 400.0)
    return dict(peaks400={t: float((P["prom"] >= t).sum() * f) for t in (30, 100, 300)}, slope400=stats.slope_stats(z, 400.0),
                hyps=stats.hypsometric(z), lrelief=stats.local_relief(z, 400.0), orient=stats.orientation(z, 400.0),
                b=stats.ccdf_exponent(P["prom"], 30, 300))


if __name__ == "__main__":
    res = {}
    for place in ("askarovo", "ongudai"):
        fl, resid = pool_for(place)
        rng = np.random.default_rng(7)
        zs = [make(fl, resid, rng) for _ in range(12)]
        np.savez_compressed(os.path.join(OUT, f"forms_gen_{place}.npz"), z400=np.array(zs, dtype=np.float32))
        res[place] = dict(resid_rms=resid, n_pool=len(fl), metrics=[metrics400(z) for z in zs])
        print(place, len(fl), resid, [m["peaks400"][100] for m in res[place]["metrics"]])
    json.dump(res, open(os.path.join(OUT, "forms_gen_metrics.json"), "w"), indent=1, default=float)
