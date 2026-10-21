#!/usr/bin/env python3
"""Сверка PendulumModel со статикой: для каждого установившегося состояния модели (V, T) решает статику
и печатает ход пилота и силу рук. Пишет out/compare.csv."""
import csv, json, sys
import numpy as np
import statics as s

cal = s.calibrate()
s.LAM0 = np.radians(cal["lam0_deg"])
s.P["emp"] = s.identify_cm([json.loads(l[4:]) for l in open("out/model_trim.txt")])
cases = [("out/model_link_pilot_eps20.csv", None)]
files = [("link/pilot", 20.0, 1.0, "out/model_T_link_pilot.txt"),
         ("link/pilot", 45.0, 1.0, "out/model_link_pilot_eps45.txt"),
         ("force/pilot", 20.0, 1.0, "out/model_force_pilot.txt"),
         ("force/split 50-50", 20.0, 0.5, "out/model_force_split.txt")]
rows = []
for tag, eps, fp, fn in files:
    try:
        lines = [json.loads(l[4:]) for l in open(fn) if l.startswith("CSV")]
    except FileNotFoundError:
        continue
    for r in lines:
        if not r.get("free") or not r.get("ok") or r["T"] == 0 or "v" not in r:
            continue
        T = r["tension"] if "tens" not in r or r["tens"] == 0 else r["tens"]
        x = None
        for v in np.linspace(s.V_T, r["v"], 12):
            _, x = s.solve(v, 0.0, eps, x, frac_pilot=fp)
        for t in np.linspace(0, T, 16):
            a, x = s.solve(r["v"], t, eps, x, frac_pilot=fp)
        rows.append(dict(case=tag, eps=eps, T=round(T), V=round(r["v"], 1), model_shift=round(r["shift"], 3),
                         statics_shift=round(a["shift"], 3), model_fx=round(r["fx"]), statics_Fb=round(a["Fb"]), ok=a["ok"]))
with open("out/compare.csv", "w", newline="") as f:
    w = csv.DictWriter(f, rows[0].keys()); w.writeheader(); w.writerows(rows)
for r in rows:
    print(r)
