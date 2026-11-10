#!/usr/bin/env python3
"""LT-12: где 70 точек W8 вне допуска (LT-9, LTM_CURRENT=1) относительно разрезов Онгудая.
w8_points.py <лог теста> -> out/w8_points.csv. Лог: строки 'ongudai_<случай> #i: σ_u model против эталон; lee_f .. r .. agl .. du ..' (cargo test ... ongudai_sigma_turb_within_w8 -- --nocapture с LTM_CURRENT=1).
Позиция точки — запись дампа RW-8 (x, y MSL, z). Для ongudai_strong (ветер 151°, как у разрезов) считаются x/H и смещение поперёк от ближайшего из 6 гребней (ridges.json); у остальных случаев ветер другой — только позиция и agl."""
import csv, json, math, os, re, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
R = json.load(open(os.path.join(HERE, "..", "stand", "ridges.json")))
rows = []
for ln in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"(ongudai_\w+) #(\d+): σ_u ([\d.]+) против ([\d.]+); lee_f ([\d.]+) r ([-\d.]+) agl ([-\d.]+) du ([-\d.]+)", ln)
    if not m:
        continue
    case, i = m.group(1), int(m.group(2))
    b = np.fromfile(os.path.join(ROOT, "rust/dp-air/tests/data/RW-8/dbg_%s.f64" % case)).reshape(-1, 64)
    x, y, z = b[i, :3]
    d = dict(case=case, idx=i, x=x, y_msl=y, z=z, agl=float(m.group(7)), sigma_u_model=float(m.group(3)), sigma_u_ref=float(m.group(4)), ratio=float(m.group(3)) / float(m.group(4)),
             lee_f=float(m.group(5)), relief_r=float(m.group(6)), du=float(m.group(8)), ridge="", x_over_h="", cross_m="", height_over_crest_m="")
    if case == "ongudai_strong":
        best = None
        for r in R:
            dx, dz = r["dir"]
            a = (x - r["frm"][0]) * dx + (z - r["frm"][1]) * dz
            c = -(x - r["frm"][0]) * dz + (z - r["frm"][1]) * dx
            cc = -(r["crest_x"] - r["frm"][0]) * dz + (r["crest_z"] - r["frm"][1]) * dx
            xh = (a - 2 * r["H"]) / r["H"]
            if best is None or abs(c - cc) < abs(best[2]):
                best = (r, xh, c - cc)
        r, xh, cr = best
        d.update(ridge=r["name"], x_over_h=xh, cross_m=cr, height_over_crest_m=y - r["crest_msl"])
    rows.append(d)
with open(os.path.join(HERE, "out", "w8_points.csv"), "w", newline="", encoding="utf-8") as fh:
    w = csv.DictWriter(fh, list(rows[0].keys())); w.writeheader()
    for d in rows:
        w.writerow({k: ("%.5g" % v if isinstance(v, (float, np.floating)) else v) for k, v in d.items()})
print(len(rows))
