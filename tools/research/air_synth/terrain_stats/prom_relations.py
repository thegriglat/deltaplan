"""Связь prominence с расстоянием до вершины-родителя (изоляцией в пределах области) и с высотой над минимумом области:
степенные подгонки по вершинам prom>=30 м (из out/peaks_*.npz) -> out/prom_relations.json"""
import json, os, numpy as np
from scipy.stats import spearmanr
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
res = {}
for place in ("askarovo", "ongudai", "altai", "aushkul"):
    for name in ("detail100", "far100"):
        d = np.load(os.path.join(OUT, f"peaks_{place}_{name}.npz"))
        m = (d["prom"] >= 30) & (d["d_parent"] > 0) & (d["d_parent"] < 60000)       # без главного максимума области
        P, dp, ds = d["prom"][m], d["d_parent"][m], d["d_saddle"][m]
        k = np.polyfit(np.log(P), np.log(dp), 1)
        res[f"{place}_{name}"] = dict(n=int(m.sum()), spearman_prom_dparent=float(spearmanr(P, dp)[0]), dparent_exp=float(k[0]),
                                      dparent_at_P100_km=float(np.exp(np.polyval(k, np.log(100))) / 1000),
                                      dsaddle_med_km=float(np.median(ds) / 1000), dsaddle_over_P=float(np.median(ds / P)))
json.dump(res, open(os.path.join(OUT, "prom_relations.json"), "w"), indent=1)
for k, v in res.items(): print(k, {a: round(b, 3) for a, b in v.items()})
