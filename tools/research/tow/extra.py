#!/usr/bin/env python3
"""Доп. точки статики: большие T лебёдки (до 1300 Н) и чувствительность к CdA пилота и массе. → out/statics_extra.json"""
import json
import numpy as np
import statics as s

s.setup([json.loads(l[4:]) for l in open("out/model_trim.txt") if l.startswith("CSV")])
out = []
for V in (10.0, 12.0, 14.0):
    for eps in (45.0, 60.0):
        for name, fp, sf in (("грудь 100/0", 1.0, 0.0), ("50/50", 0.5, 0.0)):
            x = None
            for v in np.linspace(s.V_T, V, 12):
                _, x = s.solve(v, 0.0, eps, x, frac_pilot=fp, s_fwd=sf)
            row = dict(V=V, eps=eps, bridle=name)
            for T in range(0, 1301, 50):
                r, x = s.solve(V, float(T), eps, x, frac_pilot=fp, s_fwd=sf)
                if T in (590, 900, 1000, 1300):
                    row[f"shift_T{T}"] = round(r["shift"], 3); row[f"Fb_T{T}"] = round(r["Fb"]); row[f"alpha_T{T}"] = round(r["alpha"], 1)
                    row[f"gamma_T{T}"] = round(r["gamma"], 1); row[f"ok{T}"] = r["ok"]
            out.append(row)
json.dump(out, open("out/statics_extra.json", "w"), indent=1)
for r in out: print(r)
