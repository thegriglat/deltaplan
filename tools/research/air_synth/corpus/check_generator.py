"""Проверка статистик генератора (S3) против 4 реальных мест (план §2).
Запуск: OMP_NUM_THREADS=1 .venv/bin/python check_generator.py --n 40 --seed 1 --workers 16
Конец смеси «Урал» (mix < 0,3) сравнивается с Аскарово+Аушкуль, «Онгудай/Алтай» (mix > 0,7) — с Онгудаем и Алтаем.
Реальные значения места: детальный квадрат 40×40 км и медиана 16 квадратов far (ширина по концу — min/max этих значений
у двух мест); допуск: медиана выборки в [0,67·min; 1,5·max]. Пишет out_check/check_v1.json."""
import argparse, json, os, sys, time
import numpy as np
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
TS = os.path.join(HERE, "..", "terrain_stats")
sys.path.insert(0, TS)
import generator as G          # noqa: E402
import compare                 # noqa: E402  (terrain_stats, только чтение)

REAL = json.load(open(os.path.join(TS, "out", "stats.json")))
ENDS = {"ural": ["askarovo", "aushkul"], "ongudai_altai": ["ongudai", "altai"]}

# (имя, сетка, извлекатель из compare.metrics, извлекатель из stats.json для места)
def _pk(g, t):
    return (lambda m: m["peaks%d" % g][t]), (lambda s: s["peaks_per_sq"][str(t)])

METRICS = [
    ("peaks>=30 (400м)",) + (400,) + _pk(400, 30),
    ("peaks>=100 (400м)",) + (400,) + _pk(400, 100),
    ("peaks>=300 (400м)",) + (400,) + _pk(400, 300),
    ("peaks>=30 (100м)",) + (100,) + _pk(100, 30),
    ("peaks>=100 (100м)",) + (100,) + _pk(100, 100),
    ("перепад, м (400м)", 400, lambda m: m["hyps"]["relief"], lambda s: s["hyps"]["relief"]),
    ("ср. уклон, ° (400м)", 400, lambda m: m["slope400"]["mean"], lambda s: s["slope"]["mean"]),
    ("ср. уклон, ° (100м)", 100, lambda m: m["slope100"]["mean"], lambda s: s["slope"]["mean"]),
    ("вытянутость", 400, lambda m: m["orient"]["anisotropy"], lambda s: s["orient"]["anisotropy"]),
    ("β 1–3 км (100м)", 100, lambda m: m["beta"]["1000-3000"], lambda s: s["beta"]["1000-3000"]),
    ("плотность русел, км/км² (100м)", 100, lambda m: m["drain"]["1.0"]["Dd_km_per_km2"], lambda s: s["drain"]["1.0"]["Dd_km_per_km2"]),
]


def work(a):
    seed, rid = a
    t0 = time.time()
    p, z = G.generate(seed, rid)
    sec = time.time() - t0
    z400 = z.reshape(96, 4, 96, 4).mean(axis=(1, 3))
    m = compare.metrics(z, z400)
    return rid, float(p.mix), sec, m


def real_vals(place, grid, fr):
    S = REAL[place]
    d = [fr(S["detail%d" % grid][0])]
    far = [fr(s) for s in S["far%d" % grid]]
    far = [x for x in far if x is not None and not np.isnan(x)]
    return d + ([float(np.median(far))] if far else [])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=40)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--out", default=os.path.join(HERE, "out_check"))
    a = ap.parse_args()
    with Pool(a.workers) as pool:
        res = pool.map(work, [(a.seed, i) for i in range(a.n)], chunksize=1)
    res.sort()
    mix = np.array([r[1] for r in res]); secs = np.array([r[2] for r in res])
    sel = {"ural": mix < 0.3, "ongudai_altai": mix > 0.7, "all": np.ones(len(mix), bool)}
    table, out_n = [], 0
    for name, grid, fm, fr in METRICS:
        vals = np.array([float(fm(r[3])) for r in res])
        row = {"metric": name, "grid_m": grid}
        allreal = []
        for end, places in ENDS.items():
            rv = [v for pl in places for v in real_vals(pl, grid, fr)]
            allreal += rv
            lo, hi = 0.67 * min(rv), 1.5 * max(rv)
            med = float(np.median(vals[sel[end]])) if sel[end].any() else float("nan")
            bad = bool(not (lo <= med <= hi))
            out_n += bad
            row[end] = dict(n=int(sel[end].sum()), median=med, real_min=min(rv), real_max=max(rv), lo=lo, hi=hi, out=bad,
                            gen_p10=float(np.percentile(vals[sel[end]], 10)) if sel[end].any() else None,
                            gen_p90=float(np.percentile(vals[sel[end]], 90)) if sel[end].any() else None)
        lo, hi = 0.67 * min(allreal), 1.5 * max(allreal)
        med = float(np.median(vals))
        row["all"] = dict(n=len(vals), median=med, lo=lo, hi=hi, out=bool(not (lo <= med <= hi)))
        table.append(row)
    print(f"{'метрика':34s} {'Урал: мед [реал мин–макс]':34s} {'Онгудай/Алтай: мед [реал мин–макс]':38s} общий")
    for r in table:
        u, o, al = r["ural"], r["ongudai_altai"], r["all"]
        f = lambda e: f"{e['median']:9.3g} [{e['real_min']:.3g}–{e['real_max']:.3g}]{'  ВНЕ' if e['out'] else ''}"
        print(f"{r['metric']:34s} {f(u):34s} {f(o):38s} {al['median']:.3g}{' ВНЕ' if al['out'] else ''}")
    summ = dict(n=a.n, seed=a.seed, generator_version=G.GENERATOR_VERSION, mix_quantiles=[float(x) for x in np.quantile(mix, [0, .1, .25, .5, .75, .9, 1])],
                n_ural=int(sel["ural"].sum()), n_ongudai=int(sel["ongudai_altai"].sum()),
                sec_per_relief_median=float(np.median(secs)), sec_per_relief_p90=float(np.percentile(secs, 90)),
                out_of_range=int(out_n), table=table)
    os.makedirs(a.out, exist_ok=True)
    json.dump(summ, open(os.path.join(a.out, "check_v1.json"), "w"), indent=1, ensure_ascii=False)
    print(f"mix: n_ural={summ['n_ural']} n_ongudai={summ['n_ongudai']}; sec_per_relief_median={np.median(secs):.1f}")
    print(f"out_of_range={out_n}")


if __name__ == "__main__":
    main()
