"""Статистики 4 реальных мест игры (detail 25 м, 40x40 км; far 100 м, 160x160 км = 16 квадратов 40x40 км).
Запуск: .venv/bin/python run_stats.py  ->  out/stats.json, out/peaks_<место>_<слой>.npz, out/stats_tables.md"""
import json, os, numpy as np
import dem, stats

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
TH = [10, 30, 50, 100, 200, 300, 500]
BANDS = [(10000, 40000), (3000, 10000), (1000, 3000), (400, 1000), (200, 400), (100, 200)]


def square_stats(sq, dx):
    d = dict(slope=stats.slope_stats(sq, dx), orient=stats.orientation(sq, dx),
             asym=stats.slope_asymmetry(sq, dx), hyps=stats.hypsometric(sq),
             lrelief2500=stats.local_relief(sq, dx), crit=stats.critical_counts(sq))
    return d


def datasets(place):
    """(имя, массив, шаг, сторона квадрата в клетках, n квадратов по стороне)"""
    hd, _, _ = dem.load(place, "detail"); hf, _, _ = dem.load(place, "far")
    yield "detail25", hd[:1600, :1600], 25.0
    yield "detail100", dem.coarsen(hd, 4), 100.0
    yield "detail400", dem.coarsen(hd, 16), 400.0
    yield "far100", hf[:1600, :1600], 100.0
    yield "far400", dem.coarsen(hf, 4), 400.0


def main():
    os.makedirs(OUT, exist_ok=True)
    R = {}
    for place in dem.PLACES:
        R[place] = {}
        for name, h, dx in datasets(place):
            nsq_side = int(round(h.shape[0] * dx / 40000.0))
            n = int(round(40000.0 / dx))
            P = stats.peaks(h, dx)
            np.savez_compressed(os.path.join(OUT, f"peaks_{place}_{name}.npz"), **{k: v[P["prom"] >= 10] for k, v in P.items()})
            sq_res = []
            for i in range(nsq_side):
                for j in range(nsq_side):
                    sq = h[i * n:(i + 1) * n, j * n:(j + 1) * n]
                    sel = (P["y"] >= i * 40000) & (P["y"] < (i + 1) * 40000) & (P["x"] >= j * 40000) & (P["x"] < (j + 1) * 40000)
                    pr = P["prom"][sel]
                    d = square_stats(sq, dx)
                    d["peaks_per_sq"] = {str(t): int((pr >= t).sum()) for t in TH}
                    d["prom_exp_b"] = {"30-300": stats.ccdf_exponent(pr, 30, 300), "10-100": stats.ccdf_exponent(pr, 10, 100)}
                    for q in (50, 95):
                        d[f"prom_p{q}_of_ge30"] = float(np.percentile(pr[pr >= 30], q)) if (pr >= 30).sum() else None
                    m = sel & (P["prom"] >= 30)
                    if m.sum():
                        d["ge30"] = dict(
                            prom_over_rel_height=float(np.median(P["prom"][m] / np.maximum(P["h"][m] - sq.min(), 1))),
                            d_parent_med=float(np.median(P["d_parent"][m])), d_saddle_med=float(np.median(P["d_saddle"][m])))
                    k, Pk, Pr_, Pc_ = stats.profile_psd(sq, dx)
                    bands = [b for b in BANDS if b[0] >= 4 * dx]
                    d["beta"] = stats.beta_bands(k, Pk, bands)
                    d["psd_rows_over_cols"] = float(np.exp(np.mean(np.log(Pr_[(1 / k > 1000)] / Pc_[(1 / k > 1000)]))))
                    if dx <= 100:
                        d["drain"] = stats.drainage(sq, dx)
                    sq_res.append(d)
            R[place][name] = sq_res
            print(place, name, len(sq_res), "squares; peaks>=100:", [s["peaks_per_sq"]["100"] for s in sq_res][:16], flush=True)
    json.dump(R, open(os.path.join(OUT, "stats.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
