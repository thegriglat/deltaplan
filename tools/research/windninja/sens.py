"""Чувствительность WindNinja: версия, растительность, разрешение DEM (медианы по случаям) и сам с собой.
python sens.py → out/sens.md"""
import json
import numpy as np
from common import *
from wnlib import *
cases = json.load(open(OUT / "cases.json"))["cases"]
SUB = "askarovo_002,ongudai_007,t_0321_000,t_0336_000,t_0353_003,t_0313_006".split(",")
md = ["## Метрики сравнения с решателем (60 м): медианы по случаям\n",
      "| вариант WindNinja | n | мед|Δ(u,v)| | p90|Δ(u,v)| | смещ. скор. | corr | ср./кромка | гребни/кромка | время, с |", "|---|---|---|---|---|---|---|---|---|"]
for name, tag, dem in (("3.13 трава, DEM 400 м", "mass", "d400"), ("3.13 трава, DEM 100 м", "mass", "d100"), ("4.0 трава, DEM 400 м", "v4", "d400"),
                       ("4.0 трава, DEM 100 м", "v4", "d100"), ("3.13 кустарник, 400 м", "brush", "d400"), ("3.13 лес, 400 м", "trees", "d400")):
    r = json.load(open(OUT / f"metrics_{tag}_60.json")); r = [x for x in r if x["dem"] == dem]
    m = lambda k: np.median([x[k] for x in r])
    md.append(f"| {name} | {len(r)} | {m('med_dvec'):.2f} | {m('p90_dvec'):.2f} | {m('bias_speed'):+.2f} | {m('corr_speed'):.2f} | {m('mean_over_up_wn'):.2f} | {m('ridge_over_up_wn'):.2f} | {m('sim_s'):.1f} |")
md.append("\n### Подмножество из 6 случаев: DEM 400 / 100 / 50 м (3.13, трава)\n")
md.append("| DEM | мед|Δ| | p90|Δ| | смещ. | corr | гребни/кромка WN | время, с |"); md.append("|---|---|---|---|---|---|---|")
r = json.load(open(OUT / "metrics_mass_60.json"))
for dem in ("d400", "d100", "d50"):
    q = [x for x in r if x["dem"] == dem and x["id"] in SUB]; m = lambda k: np.median([x[k] for x in q])
    md.append(f"| {dem} | {m('med_dvec'):.2f} | {m('p90_dvec'):.2f} | {m('bias_speed'):+.2f} | {m('corr_speed'):.2f} | {m('ridge_over_up_wn'):.2f} | {m('sim_s'):.1f} |")
md.append("\n### WindNinja против самого себя (на клетках 400 м, без края), |Δ(u,v)|, м/с: медиана / p90 по клеткам, медиана по случаям\n")
md.append("| пара | n | медиана | p90 |"); md.append("|---|---|---|---|")
def pair(t1, d1, t2, d2, ids, label):
    med, p90 = [], []
    for cid in ids:
        a = wn_uv(t1, d1, "60", cid); b = wn_uv(t2, d2, "60", cid)
        d = np.hypot(a[0] - b[0], a[1] - b[1])[EDGE:-EDGE, EDGE:-EDGE]
        med.append(np.median(d)); p90.append(np.percentile(d, 90))
    md.append(f"| {label} | {len(ids)} | {np.median(med):.2f} | {np.median(p90):.2f} |")
allid = [c["id"] for c in cases]
pair("mass", "d400", "mass", "d100", allid, "DEM 100 м против 400 м (3.13)")
pair("mass", "d100", "mass", "d50", SUB, "DEM 50 м против 100 м (3.13)")
pair("mass", "d400", "v4", "d400", allid, "4.0 против 3.13 (400 м)")
pair("mass", "d400", "trees", "d400", allid, "лес против травы (3.13)")
pair("mass", "d400", "brush", "d400", allid, "кустарник против травы (3.13)")
(OUT / "sens.md").write_text("\n".join(md) + "\n"); print("\n".join(md))
