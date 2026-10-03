"""Сводка метрик: медианы по случаям места × DEM → out/summary_<tag>_<h>.md. python summarize.py [--tag mass] [--h 60]"""
import argparse, json
import numpy as np
from common import OUT, PLACES
ap = argparse.ArgumentParser(); ap.add_argument("--tag", default="mass"); ap.add_argument("--h", default="60"); a = ap.parse_args()
rows = json.load(open(OUT / f"metrics_{a.tag}_{a.h}.json"))
K = ["med_dvec", "p90_dvec", "bias_speed", "corr_speed", "dir_med_deg", "ridge_bias", "ridge_ratio_wn", "ridge_ratio_sol",
     "valley_bias", "up_speed_wn", "up_speed_sol", "mean_speed_wn", "mean_speed_sol", "struct_sol", "sim_s", "mean_over_up_wn", "mean_over_up_sol", "ridge_over_up_wn", "ridge_over_up_sol", "med_dvec_centered"]
md = []
def table(sel, title):
    md.append(f"\n### {title}\n")
    md.append("| место | DEM | n | мед|Δ(u,v)| | p90|Δ(u,v)| | смещение скор. (WN−реш.) | corr скор. | Δнапр. мед, ° | гребни: смещ. | гребни: разгон WN / реш. | долины: смещ. | WN, с |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for loc in PLACES + ["all"]:
        for dem in ("d400", "d100"):
            r = [x for x in rows if (loc == "all" or x["loc"] == loc) and x["dem"] == dem and sel(x)]
            if not r: continue
            m = lambda k: np.median([x[k] for x in r])
            md.append(f"| {loc} | {dem} | {len(r)} | {m('med_dvec'):.2f} | {m('p90_dvec'):.2f} | {m('bias_speed'):+.2f} | {m('corr_speed'):.2f} | "
                      f"{m('dir_med_deg'):.0f} | {m('ridge_bias'):+.2f} | {m('ridge_ratio_wn'):.2f} / {m('ridge_ratio_sol'):.2f} | {m('valley_bias'):+.2f} | {m('sim_s'):.1f} |")
md.append("\n### Торможение и разгон относительно притока (скорость на 60 м; кромка = наветренная полоса 5 клеток)\n")
md.append("| место | DEM | n | среднее/кромка WN | среднее/кромка реш. | гребни/кромка WN | гребни/кромка реш. | мед|Δ| без смещения |")
md.append("|---|---|---|---|---|---|---|---|")
for loc in PLACES + ["all"]:
    for dem in ("d400", "d100"):
        r = [x for x in rows if (loc == "all" or x["loc"] == loc) and x["dem"] == dem]
        if not r: continue
        m = lambda k: np.median([x[k] for x in r])
        md.append(f"| {loc} | {dem} | {len(r)} | {m('mean_over_up_wn'):.2f} | {m('mean_over_up_sol'):.2f} | {m('ridge_over_up_wn'):.2f} | {m('ridge_over_up_sol'):.2f} | {m('med_dvec_centered'):.2f} |")
table(lambda x: True, "Все случаи (медианы по случаям)")
table(lambda x: x["U10"] < 6, "U10 < 6 м/с")
table(lambda x: x["U10"] >= 6, "U10 ≥ 6 м/с")
md.append("\n### По случаям (d400 / d100)\n")
md.append("| случай | U10 | напр. | DEM | мед|Δ| | p90|Δ| | смещ. | corr | ср.скор WN | ср.скор реш. | наветр. кромка WN | реш. | WN, с | реш., с |")
md.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for x in rows:
    md.append(f"| {x['id']} | {x['U10']} | {x['wdir']:.0f} | {x['dem']} | {x['med_dvec']:.2f} | {x['p90_dvec']:.2f} | {x['bias_speed']:+.2f} | {x['corr_speed']:.2f} | {x['mean_speed_wn']:.2f} | {x['mean_speed_sol']:.2f} | {x['up_speed_wn']:.2f} | {x['up_speed_sol']:.2f} | {x['sim_s']:.1f} | {x['t_solver_s']:.0f} |")
(OUT / f"summary_{a.tag}_{a.h}.md").write_text("\n".join(md) + "\n")
print("\n".join(md[:40]))
