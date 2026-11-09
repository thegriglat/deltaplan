#!/usr/bin/env python3
import sys, json
from parse_probe import read
L = "/home/greg/worktrees/deltaplan/picard-terrain-PT-14/tools/research/picard_terrain/out/PT-14/logs/"
def table(sha, tag, agl):
    rows = [d for d in read(L + f"{sha}-probe_ridge.log") if d["tag"] == tag + ".pt" and d["agl"] == agl]
    return {d["x"]: d for d in rows}
if __name__ == "__main__":
    tag = sys.argv[1]; agl = float(sys.argv[2])
    shas = sys.argv[3:]
    ts = {s: table(s, tag, agl) for s in shas}
    xs = sorted(next(iter(ts.values())).keys())
    print("x   " + "  ".join(f"{s[:7]:>34}" for s in shas))
    print("    " + "  ".join(f"{'mean_u':>7} {'mean_w':>7} {'fld_w':>7} {'sig_tot':>7} {'turb_s':>7}" for s in shas))
    for x in xs:
        cells = []
        for s in shas:
            d = ts[s].get(x)
            if not d: cells.append(" " * 34); continue
            fw = d["vel"]["field"][1]
            cells.append(f"{d['mean'][0]:7.2f} {d['mean'][1]:7.2f} {fw:7.2f} {d['total_sigma']:7.2f} {d['sigma'].get('turb', float('nan')):7.2f}")
        print(f"{x:6.0f} " + "  ".join(cells))
