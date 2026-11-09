#!/usr/bin/env python3
"""Сравнение зондов крейта по коммитам: средний поток, u*, признак отрыва, σ."""
import json, sys
O = "/home/greg/worktrees/deltaplan/picard-terrain-PT-14/tools/research/picard_terrain/out/PT-14/probe/"
SH = ["f44c66b4a", "4316db7e0", "9d94bf30c"]
def load(sha, name):
    d = json.load(open(O + f"{sha}-{name}.json"))
    return d, {(p["x"], p["agl"]): p for p in d["points"]}
if __name__ == "__main__":
    name = sys.argv[1]; agl = float(sys.argv[2])
    D = {s: load(s, name) for s in SH}
    for s in SH:
        print(s, [(l["dx"], l["nx"], l["nz"], l["dz"]) for l in D[s][0]["levels"]], "z0", D[s][0]["z0"])
    keys = sorted({k for k in D[SH[0]][1] if k[1] == agl})
    hdr = ["uf", "wf", "ustar", "u_out", "a_out", "desc", "lee_f", "u_h", "sig_turb"]
    print("agl", agl)
    print("   x |" + "|".join(f"{s[:6]:^64}" for s in SH))
    print("     |" + "|".join(f"{'uf':>7}{'wf':>7}{'u*':>7}{'uout':>7}{'aout':>7}{'desc':>7}{'leeF':>7}{'sTrb':>7}{'dx':>6}" for s in SH))
    for k in keys:
        cells = []
        for s in SH:
            p = D[s][1][k]; tb = p["tb"]
            cells.append(f"{p['uf']:7.2f}{p['wf']:7.2f}{tb['ustar']:7.2f}{tb['u_out']:7.2f}{tb['a_out']:7.0f}{tb['desc']:7.3f}{p['lee_f']:7.2f}{p['sigma'].get('turb',0):7.2f}{p['dx_cell']:6.0f}")
        print(f"{k[0]:5.0f}|" + "|".join(cells))
