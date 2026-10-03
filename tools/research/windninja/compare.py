"""Сравнение WindNinja с решателем на 60 м (клетки 400 м, без EDGE клеток у края).
python compare.py [--tag mass] [--h 60] → out/metrics_<tag>.json, out/metrics_<tag>.csv, out/summary_<tag>.md"""
import argparse, json, glob
import numpy as np
from common import *
from wnlib import *

ap = argparse.ArgumentParser(); ap.add_argument("--tag", default="mass"); ap.add_argument("--h", default="60")
ap.add_argument("--dems", default="d400,d100"); a = ap.parse_args()
meta = json.load(open(OUT / "cases.json")); cases = meta["cases"]
runs = json.load(open(OUT / f"runs_{a.tag}.json"))


rows = []
for c in cases:
    z = np.load(OUT / f"ref_{c['id']}.npz")
    h = a.h
    ur, vr = z[f"u{h}"], z[f"v{h}"]
    for dem in a.dems.split(","):
        key = f"{c['id']}|{dem}|{h}"
        if key not in runs or runs[key].get("sim") is None:
            continue
        u, v = wn_uv(a.tag, dem, h, c["id"])
        r = dict(id=c["id"], loc=c["loc"], dem=dem, U10=c["U10"], wdir=c["wdir"], sim_s=runs[key]["sim"],
                 wall_s=runs[key]["wall"], t_solver_s=c["t_solver_m"])
        r.update(stats(u, v, ur, vr, z["hc"], c["wdir"]))
        rows.append(r)
        np.savez_compressed(OUT / "maps" / f"{a.tag}_{dem}_{h}_{c['id']}.npz", u=u.astype(np.float32), v=v.astype(np.float32)) if (OUT / "maps").is_dir() else None
json.dump(rows, open(OUT / f"metrics_{a.tag}_{h}.json", "w"), indent=1)
import csv
with open(OUT / f"metrics_{a.tag}_{h}.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
print(len(rows), "строк")
