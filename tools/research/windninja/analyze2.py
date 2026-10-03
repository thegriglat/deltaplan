"""Профиль притока и торможение по высоте; чувствительность к растительности и версии; d50 на подмножестве.
python analyze2.py → out/analysis2.md, out/analysis2.json (после run.py / batch2.sh)"""
import json
import numpy as np
from common import *
from wnlib import *

SUB = "askarovo_002,ongudai_007,t_0321_000,t_0336_000,t_0353_003,t_0313_006".split(",")
cases = {c["id"]: c for c in json.load(open(OUT / "cases.json"))["cases"]}
HS = [10, 20, 30, 60, 100, 150, 200]
md, js = [], {}


def strip(u, v, wdir, e=EDGE):
    ex, ey = -np.sin(np.radians(wdir)), -np.cos(np.radians(wdir))
    m = np.zeros(u.shape, bool)
    if abs(ex) > 0.38:
        m[:, :e] = ex > 0
        if ex < 0: m[:, -e:] = True
    if abs(ey) > 0.38:
        if ey > 0: m[:e, :] = True
        else: m[-e:, :] = True
    sp = np.hypot(u, v)
    return sp[m].mean(), sp[e:-e, e:-e].mean()


md.append("## Профиль по высоте: наветренная кромка / среднее по области, м/с (случаи подмножества, d400)\n")
md.append("| случай | U10 | величина | " + " | ".join(f"{h} м" for h in HS) + " |")
md.append("|---|---|---|" + "---|" * len(HS))
agg = {k: [] for k in ("wn_up", "wn_mean", "flat_up", "sol_up", "sol_mean")}
for cid in SUB:
    c = cases[cid]; z = np.load(OUT / f"ref_{cid}.npz")
    r = {k: [] for k in agg}
    for h in HS:
        try:
            u, v = wn_uv("mass", "d400", str(h), cid); fu, fv = wn_uv("flat", "d400", str(h), cid)
        except StopIteration:
            for k in ("wn_up", "wn_mean", "flat_up"): r[k].append(np.nan)
        else:
            a, b = strip(u, v, c["wdir"]); r["wn_up"].append(a); r["wn_mean"].append(b)
            r["flat_up"].append(strip(fu, fv, c["wdir"])[0])
        if h >= 60 or f"u{h}" in z and h >= 40:
            a, b = strip(z[f"u{h}"], z[f"v{h}"], c["wdir"]); r["sol_up"].append(a); r["sol_mean"].append(b)
        else:
            r["sol_up"].append(np.nan); r["sol_mean"].append(np.nan)
    js[cid] = r
    for k, name in (("flat_up", "WN плоский"), ("wn_up", "WN кромка"), ("wn_mean", "WN среднее"), ("sol_up", "решатель кромка"), ("sol_mean", "решатель среднее")):
        md.append(f"| {cid} | {c['U10']} | {name} | " + " | ".join("—" if np.isnan(x) else f"{x:.2f}" for x in r[k]) + " |")
    for k in agg: agg[k].append(r[k])
md.append("\nМедиана по подмножеству (отношение «среднее по области / кромка» по высоте):\n")
md.append("| высота | WN среднее/кромка | решатель среднее/кромка | WN кромка / WN плоский | решатель кромка / WN плоский |")
md.append("|---|---|---|---|---|")
A = {k: np.array(v) for k, v in agg.items()}
for i, h in enumerate(HS):
    f = lambda x: "—" if np.isnan(x) else f"{x:.2f}"
    md.append(f"| {h} м | {f(np.nanmedian(A['wn_mean'][:, i] / A['wn_up'][:, i]))} | {f(np.nanmedian(A['sol_mean'][:, i] / A['sol_up'][:, i]))} | "
              f"{f(np.nanmedian(A['wn_up'][:, i] / A['flat_up'][:, i]))} | {f(np.nanmedian(A['sol_up'][:, i] / A['flat_up'][:, i]))} |")
(OUT / "analysis2.md").write_text("\n".join(md) + "\n"); json.dump(js, open(OUT / "analysis2.json", "w"), indent=1)
print("\n".join(md))
