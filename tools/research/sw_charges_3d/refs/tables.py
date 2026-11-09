"""SWD-1: сводка Пикар (nom, adv1) против измерений по типам точек и высотам → out/refs/tables.md, tables.json.
Статистика — по s_norm: ε = s_norm(Пикар)/s_norm(мачта) − 1 (сдвиг и rms), доля |ε| ≤ 0,15 (не оценка модели — справка для SWD-5)."""
import json
from pathlib import Path
import numpy as np

OUT = Path(__file__).resolve().parent.parent / "out/refs"
d = json.load(open(OUT / "points.json"))
R = d["rows"]
idx = {(r["case"], r["name"], r["z_agl"], r["ref_kind"]): r for r in R}
res, md = [], ["# Пикар против измерений (мачты), s_norm", "",
               "ε = s_norm(Пикар)/s_norm(мачта) − 1; сдвиг = среднее ε, rms; «в ±15 %» — доля |ε| ≤ 0,15. Только справка: "
               "оценка схемы — SWD-5.", "", "| случай | вариант | группа | n | сдвиг | rms | в ±15 % |", "|---|---|---|---|---|---|---|"]
for c in ("ASK_TU03B", "PERD_NE", "PERD_SW"):
    for v in ("picard_nom", "picard_adv1"):
        groups = {}
        for m in R:
            if m["case"] != c or m["ref_kind"] != "mast":
                continue
            p = idx.get((c, m["name"], m["z_agl"], v))
            if not p:
                continue
            e = p["s_norm"] / m["s_norm"] - 1
            for g in ("все", m["point"], f"z={m['z_agl']:g} м" if m["z_agl"] in (10, 30, 60, 100) else None):
                if g:
                    groups.setdefault(g, []).append(e)
        for g, es in groups.items():
            a = np.array(es)
            res.append(dict(case=c, variant=v, group=g, n=len(a), bias=float(a.mean()), rms=float(np.sqrt((a ** 2).mean())),
                            frac15=float((np.abs(a) <= 0.15).mean())))
            md.append(f"| {c} | {v} | {g} | {len(a)} | {a.mean():+.3f} | {np.sqrt((a ** 2).mean()):.3f} | {(np.abs(a) <= .15).mean():.2f} |")
md += ["", "# Синтетические точки Пикара: s_norm по типам и высотам (nom / adv1; adv1/nom − 1)", "",
       "| случай | точка | z_agl | s_norm nom | s_norm adv1 | adv1/nom − 1 |", "|---|---|---|---|---|---|"]
for c in ("ASK_TU03B", "PERD_NE", "PERD_SW"):
    for pt in ("upstream", "windward", "crest", "lee", "valley"):
        for z in (10.0, 50.0, 300.0):
            a = idx[(c, f"P_{pt}_0", z, "picard_nom")]
            b = idx[(c, f"P_{pt}_0", z, "picard_adv1")]
            md.append(f"| {c} | {pt} | {z:g} | {a['s_norm']:.3f} | {b['s_norm']:.3f} | {b['s_norm'] / a['s_norm'] - 1:+.3f} |")
md += ["", "# Ротор (u∥ < −0,5 м/с на 15 м, > 50 м)", "", "| случай | разрез | источник | есть | L, м | глубина, м |", "|---|---|---|---|---|---|"]
for r in d["rotor"]:
    md.append(f"| {r['case']} | {r['transect']} | {r['source']} | {r['present']} | {r['L_m']} | {r['depth_m']} |")
(OUT / "tables.md").write_text("\n".join(md) + "\n")
(OUT / "tables.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
print("\n".join(md[:40]))
