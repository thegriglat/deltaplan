"""Таблица «реальный vs Fastscape vs сумма форм» -> out/compare_tables.md. Медиана [мин–макс] по 12 рельефам / 16 квадратам."""
import json, os, numpy as np
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
S = json.load(open(os.path.join(OUT, "stats.json")))
F = json.load(open(os.path.join(OUT, "fastscape_metrics.json")))["metrics"]
G = json.load(open(os.path.join(OUT, "forms_gen_metrics.json")))


def fmt(v):
    v = np.array([x for x in v if x is not None and not np.isnan(x)], float)
    if len(v) == 0: return "–"
    if len(v) == 1: return f"{v[0]:.3g}"
    return f"{np.median(v):.3g} [{v.min():.3g}–{v.max():.3g}]"


# величины на сетке 400 м (то, что видит решатель): (имя, real-извлекатель, fastscape-извлекатель, forms-извлекатель)
Q = [("перепад в квадрате, м", lambda s: s["hyps"]["relief"], lambda m: m["hyps"]["relief"], lambda m: m["hyps"]["relief"]),
     ("std высот, м", lambda s: s["hyps"]["std"], lambda m: m["hyps"]["std"], lambda m: m["hyps"]["std"]),
     ("гипсометрический интеграл", lambda s: s["hyps"]["HI"], lambda m: m["hyps"]["HI"], lambda m: m["hyps"]["HI"]),
     ("ср. уклон на 400 м, °", lambda s: s["slope"]["mean"], lambda m: m["slope400"]["mean"], lambda m: m["slope400"]["mean"]),
     ("p99 уклона на 400 м, °", lambda s: s["slope"]["p99"], lambda m: m["slope400"]["p99"], lambda m: m["slope400"]["p99"]),
     ("вершины prom ≥30 м / 40×40 км", lambda s: s["peaks_per_sq"]["30"], lambda m: m["peaks400"]["30"], lambda m: m["peaks400"]["30"]),
     ("вершины prom ≥100 м", lambda s: s["peaks_per_sq"]["100"], lambda m: m["peaks400"]["100"], lambda m: m["peaks400"]["100"]),
     ("вершины prom ≥300 м", lambda s: s["peaks_per_sq"]["300"], lambda m: m["peaks400"]["300"], lambda m: m["peaks400"]["300"]),
     ("анизотропия тензора", lambda s: s["orient"]["anisotropy"], lambda m: m["orient"]["anisotropy"], lambda m: m["orient"]["anisotropy"])]
Q100 = [("ср. уклон на 100 м, °", lambda s: s["slope"]["mean"], lambda m: m["slope100"]["mean"]),
        ("p99 уклона на 100 м, °", lambda s: s["slope"]["p99"], lambda m: m["slope100"]["p99"]),
        ("вершины prom ≥30 м (100 м)", lambda s: s["peaks_per_sq"]["30"], lambda m: m["peaks100"]["30"]),
        ("вершины prom ≥100 м (100 м)", lambda s: s["peaks_per_sq"]["100"], lambda m: m["peaks100"]["100"]),
        ("Dd при 1 км², км/км²", lambda s: s["drain"]["1.0"]["Dd_km_per_km2"], lambda m: m["drain"]["1.0"]["Dd_km_per_km2"]),
        ("β 3–10 км", lambda s: s["beta"]["3000-10000"], lambda m: m["beta"]["3000-10000"]),
        ("β 1–3 км", lambda s: s["beta"]["1000-3000"], lambda m: m["beta"]["1000-3000"])]
md = []
for place in ("askarovo", "ongudai"):
    md.append(f"\n**Тип «{place}», сетка 400 м (96² / 100²)**\n")
    md.append("| величина | реальное: detail (1 кв.) | реальное: far (16 кв.) | Fastscape (12) | сумма форм, бутстрэп (12) |\n|---|---|---|---|---|")
    for name, fr, ff, fg in Q:
        md.append(f"| {name} | {fmt([fr(s) for s in S[place]['detail400']])} | {fmt([fr(s) for s in S[place]['far400']])} | "
                  f"{fmt([ff(m) for m in F[place]])} | {fmt([fg(m) for m in G[place]['metrics']])} |")
    md.append(f"\n**Тип «{place}», сетка 100 м (Fastscape считается на ней)**\n")
    md.append("| величина | реальное: detail | реальное: far (16 кв.) | Fastscape (12) |\n|---|---|---|---|")
    for name, fr, ff in Q100:
        key = "drain" if "Dd" in name else None
        det = S[place]["detail100"]; far = S[place]["far100"]
        md.append(f"| {name} | {fmt([fr(s) for s in det])} | {fmt([fr(s) for s in far])} | {fmt([ff(m) for m in F[place]])} |")
open(os.path.join(OUT, "compare_tables.md"), "w").write("\n".join(md) + "\n")
print("\n".join(md))
