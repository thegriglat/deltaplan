#!/usr/bin/env python3
"""Сводка lee_obs.csv: TKE*/ (u_ref^2) по x/H и z/H, максимум за гребнем. Пишет summary_tke.json и печатает таблицы."""
import csv, json, os, math
HERE = os.path.dirname(os.path.abspath(__file__))
R = list(csv.DictReader(open(os.path.join(HERE, "lee_obs.csv"))))
out = {}
for site, case in sorted({(r["site"], r["case"]) for r in R}):
    rs = [r for r in R if r["site"] == site and r["case"] == case and r["tke_m2s2"]]
    t = []
    for r in rs:
        H, u = float(r["H_m"]), float(r["u_ref_ms"])
        t.append(dict(station=r["station"], xH=float(r["x_m"]) / H, zH=float(r["z_m"]) / H,
                      tke_n=float(r["tke_m2s2"]) / u**2, sig_iso_n=math.sqrt(2 * float(r["tke_m2s2"]) / 3) / u, rel=r["reliability"]))
    lee = [a for a in t if a["xH"] > 0]
    out[f"{site}_{case}"] = dict(n=len(t), n_lee=len(lee), rows=t,
                                 max_lee=max(lee, key=lambda a: a["tke_n"]) if lee else None)
json.dump(out, open(os.path.join(HERE, "summary_tke.json"), "w"), ensure_ascii=False, indent=1)
for k, v in out.items():
    print(k, v["n"], v["n_lee"], v["max_lee"] and {a: (round(b, 3) if isinstance(b, float) else b) for a, b in v["max_lee"].items()})
    for a in sorted(v["rows"], key=lambda a: (a["xH"], a["zH"])):
        if a["xH"] > -1: print("  %-28s x/H %6.2f z/H %5.2f TKE/U2 %.4f sig_iso/U %.3f %s" % (a["station"], a["xH"], a["zH"], a["tke_n"], a["sig_iso_n"], a["rel"]))
