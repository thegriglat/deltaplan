#!/usr/bin/env python3
"""Таблица стартов: коммит × точка (A — выбрана на f44c66b4a, B — на PT-9) -> w, σ, величины поля в точке."""
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse_probe import read
L = os.path.expanduser("~/worktrees/deltaplan/picard-terrain-PT-14/tools/research/picard_terrain/out/PT-14/logs/")
SH = ["f44c66b4a", "4316db7e0", "9d94bf30c"]
SRC = {("f44c66b4a", "A"): "f44c66b4a-probe_starts.log", ("f44c66b4a", "B"): "f44c66b4a-starts_pinB.log",
       ("4316db7e0", "A"): "4316db7e0-starts_pinA.log", ("4316db7e0", "B"): "4316db7e0-starts_pinB.log",
       ("9d94bf30c", "A"): "9d94bf30c-starts_pinA.log", ("9d94bf30c", "B"): "9d94bf30c-starts_pinB.log"}

def collect():
    out = {}
    for (sha, pin), fn in SRC.items():
        if not os.path.exists(L + fn):
            continue
        for d in read(L + fn):
            if d["tag"] == "start.dec":
                site, side = d["key"].rsplit(".", 1)
                out.setdefault(site, {}).setdefault((sha, pin), {})[side] = d
            elif d["tag"] == "start.summary":
                out.setdefault(d["key"], {}).setdefault((sha, pin), {})["summary"] = d
    return out

if __name__ == "__main__":
    data = collect()
    for site, rows in data.items():
        print("==", site)
        for pin in ("A", "B"):
            print(" точка", pin)
            for sha in SH:
                r = rows.get((sha, pin))
                if not r or "summary" not in r:
                    continue
                s = r["summary"]; l = r.get("lee", {}).get("chan", {}); w = r.get("wind", {}).get("chan", {})
                def f(c):
                    if not c or "uf" not in c: return "-"
                    return f"uf={c['uf']:.2f} wf={c['wf']:.2f} u*={c['ustar']:.2f} shear={c['shear']:.3f} uout={c['u_out']:.1f} desc={c['desc']:.3f} lee_f={c['lee_f']:.2f} hmix={c['hmix']:.0f}"
                print(f"  {sha[:7]}: w_lee={s['w_lee']:.2f} w_wind={s['w_wind']:.2f} σ_lee={s['sigma_lee']:.2f} σ_wind={s['sigma_wind']:.2f} ratio={s['sigma_lee']/s['sigma_wind']:.2f}")
                print("      lee :", f(l))
                print("      wind:", f(w))
