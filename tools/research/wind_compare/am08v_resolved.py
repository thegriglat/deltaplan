#!/usr/bin/env python3
"""AM-08в: разрешает ли решатель пузырь отрыва — доля точек зоны отрыва (lee_f > 0), где поле само
течёт назад, по числу клеток на длину пузыря L/dx = 2,8·r/dx (r — превышение гребня, dx — клетка
поля в точке). Данные — out/am08v/*_turb_air.json (dump_wind --diag=1), 9 м/с, AGL ≤ 50 м.
python3 am08v_resolved.py → am08v/resolved.md"""
import json, math, os
here = os.path.dirname(os.path.abspath(__file__))
BINS = [0, 2, 4, 6, 8, 10, 100]
rows = {}
for name in ("strong_turb_air", "saddle_strong_turb_air", "mountain_strong_turb_air"):
    p = os.path.join(here, "out", "am08v", name + ".json")
    if not os.path.exists(p):
        continue
    d = json.load(open(p))
    a = math.radians((d["cond"]["wind_from"] + 180) % 360)
    ex, ey = math.sin(a), math.cos(a)
    for L, lv in d["levels"].items():
        if int(L) > 50:
            continue
        for k, (r, dx, lf, uh) in enumerate(lv["diag"]):
            if lf <= 0 or dx <= 0:
                continue
            m = lv["mean"][k]
            n = 2.8 * r / dx
            win = "окна 50/100 м" if dx <= 100.5 else "область 400 м"
            b = next(i for i in range(len(BINS) - 1) if n < BINS[i + 1])
            s = rows.setdefault((win, b), [0, 0, 0.0])
            s[0] += 1
            lon = m[0] * ex + m[1] * ey
            if lon < 0:
                s[1] += 1
                s[2] = min(s[2], lon / max(uh, 0.1))
out = ["# Разрешение пузыря отрыва решателем (AM-08в)", "", " ".join(__doc__.split("\n")[:3]), "",
       "| сетка | L/dx | точек зоны | поле течёт назад, % | min u_прод/U_H поля |", "|---|---|---|---|---|"]
for (win, b), (n, nr, mn) in sorted(rows.items()):
    out.append(f"| {win} | {BINS[b]}–{BINS[b+1] if BINS[b+1] < 100 else '…'} | {n} | {100*nr/n:.0f} | {mn:.2f} |")
os.makedirs(os.path.join(here, "am08v"), exist_ok=True)
open(os.path.join(here, "am08v", "resolved.md"), "w").write("\n".join(out) + "\n")
print("\n".join(out))
