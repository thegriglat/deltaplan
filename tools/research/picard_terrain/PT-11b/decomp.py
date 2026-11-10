"""PT-11b (доп.): S = U_гребень/U_опора; разложение на числитель и знаменатель, до/после, focus и nofocus."""
import json, numpy as np
from pt11b import *
out = {}
rows = []
for it in crest_list():
    name = it["name"]
    if name not in SEL: continue
    meta = json.load(open(RAW / f"{name}_points.json"))["meta"]
    offs = json.load(open(RAW / f"{it['case']}_nofocus_offsets.json"))[name]
    for mode in ("focus", "nofocus"):
        D = {v: load(RAW / (f"{name}_focus_{v}.csv" if mode == "focus" else f"{it['case']}_nofocus_{v}.csv"), None if mode == "focus" else offs)[0.0] for v in ("before", "after")}
        for z in ZAGL:
            kc = [k for k, m in enumerate(meta) if m[0] == "crest" and m[2] == z][0]
            kp = [k for k, m in enumerate(meta) if m[0] == "plain" and m[2] == z][0]
            U = lambda v, k: float(np.hypot(D[v][k, 3], D[v][k, 5]))
            rows.append(dict(name=name, mode=mode, z_agl=z, crest_b=U("before", kc), crest_a=U("after", kc), ref_b=U("before", kp), ref_a=U("after", kp)))
json.dump(rows, open(OUT / "decomp_U.json", "w"), indent=1)
res = {}
for mode in ("focus", "nofocus"):
    R = [r for r in rows if r["mode"] == mode]
    res[mode] = dict(crest_U_after_over_before_median=float(np.median([r["crest_a"] / r["crest_b"] for r in R])),
                     ref_U_after_over_before_median=float(np.median([r["ref_a"] / r["ref_b"] for r in R])),
                     by_z={z: dict(crest_b=float(np.median([r["crest_b"] for r in R if r["z_agl"] == z])), crest_a=float(np.median([r["crest_a"] for r in R if r["z_agl"] == z])),
                                   ref_b=float(np.median([r["ref_b"] for r in R if r["z_agl"] == z])), ref_a=float(np.median([r["ref_a"] for r in R if r["z_agl"] == z]))) for z in ZAGL})
json.dump(res, open(OUT / "decomp_summary.json", "w"), indent=1)
print(json.dumps(res, indent=1))
for r in rows:
    if r["mode"] == "focus" and r["z_agl"] == 30: print(r["name"], "crest %.1f->%.1f ref %.1f->%.1f"%(r["crest_b"], r["crest_a"], r["ref_b"], r["ref_a"]))
