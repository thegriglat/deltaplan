"""Таблица пробного прогона: модель против наблюдаемых, чувствительность, χ² (как у потребителя C10) → out/trial_table.md"""
import json, math, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import numpy as np
import perdigao as P
OUT = HERE / "out"
rows = [json.loads(l) for l in (OUT / "trial_runs.jsonl").read_text().splitlines()]
R = {(r["tag"], r["subcase"]): r for r in rows}
obs = P.observations()
tags = ["nom30", "nom20", "nom40", "z0_0.1", "z0_1.8", "d0", "lam0.25"]
L = []
for sub in P.SUBCASES:
    L.append(f"### {sub.upper()}: модель (номинал dx 30 м) против данных; столбцы — варианты\n")
    L.append("| наблюдаемая | данные | σ | σ_сетки | " + " | ".join(tags) + " | (мод−данные)/σ |")
    L.append("|---|---|---|---|" + "---|" * len(tags) + "---|")
    for o in [q for q in obs if q["subcase"] == sub]:
        vals = [R[(t, sub)]["obs"].get(o["name"]) for t in tags]
        z = (vals[0] - o["data"]) / math.hypot(o["sig"], o["sig_grid"]) if vals[0] is not None else float("nan")
        L.append(f"| {o['name'].replace('pd_' + sub + '_', '')} | {o['data']:.3f} | {o['sig']:.3f} | {o['sig_grid']:.3f} | "
                 + " | ".join("—" if v is None else f"{v:.3f}" for v in vals) + f" | {z:+.1f} |")
    L.append("")
L.append("### Прогоны\n")
L.append("| вариант | подслучай | dx | статус | итераций | t решателя, с | S_ref модель, м/с | U100 данных, м/с | χ² (все наблюдаемые подслучая) | n |")
L.append("|---|---|---|---|---|---|---|---|---|---|")
for t in tags:
    for sub in P.SUBCASES:
        r = R[(t, sub)]
        ch = n = 0
        for o in [q for q in obs if q["subcase"] == sub]:
            v = r["obs"].get(o["name"])
            if v is not None:
                ch += ((v + o["grid_corr"] - o["data"]) ** 2) / (o["sig"] ** 2 + o["sig_grid"] ** 2); n += 1
        L.append(f"| {t} | {sub} | {r['dx']:g} | {r['status']} | {r['iters']} | {r['t']:.1f} | {r['inputs']['sref_model']:.2f} | {r['inputs']['u100_obs']:.2f} | {ch:.0f} | {n} |")
L.append("")
L.append("Зона по разрезам (номинал dx 30): L, м / глубина, м / max(−u_∥), м/с / H, м / D, м\n")
for sub in P.SUBCASES:
    for s in R[("nom30", sub)]["zone_sections"]:
        L.append(f"- {sub.upper()} сдвиг {s['t']:+.0f} м: L {s['L']:.0f}, глубина {s['depth']:.0f}, max(−u_∥) {s['rev']:.2f}, H {s['H']:.0f}, D {s['D']:.0f}")
(OUT / "trial_table.md").write_text("\n".join(L) + "\n")
print("\n".join(L))
