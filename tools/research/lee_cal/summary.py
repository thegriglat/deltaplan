"""Сводка run.sh: k, U над стартом на 10 м (проход 1 / итог), максимум |U| по сетке ±2,4 км на 100 и 200 м.
python3 tools/research/lee_cal/summary.py before after"""
import json, math, re, sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
U10 = 6.0
RX = re.compile(r"k притока ([0-9.]+), U над стартом на 10 м ([0-9.]+) м/с(?: \(проход 1: ([0-9.]+))?.*?проходов (\d)")
def row(tag, n):
    p = os.path.join(HERE, "out", tag, n)
    if not os.path.exists(p + ".json"):
        return None
    d = json.load(open(p + ".json"))
    R = d["rows"]
    m = [max(math.hypot(r[3 + 3 * i], r[4 + 3 * i]) for r in R) for i in range(3)]
    g = RX.search(open(p + ".log").read())
    k, u, u1, np = (g.group(1), g.group(2), g.group(3) or g.group(2), g.group(4)) if g else ("?",) * 4
    return k, u1, u, np, m
tags = sys.argv[1:] or ["before", "after"]
names = sorted({f[:-5] for t in tags for f in os.listdir(os.path.join(HERE, "out", t)) if f.endswith(".json")})
print("| старт | " + " | ".join(f"{t}: k / U₁ / U10 / проходов / max30,100,200 (×меню 100–200)" for t in tags) + " |")
print("|---|" + "---|" * len(tags))
for n in names:
    cells = []
    for t in tags:
        r = row(t, n)
        if r is None:
            cells.append("—"); continue
        k, u1, u, np, m = r
        cells.append(f"{k} / {u1} / {u} / {np} / {m[0]:.1f}, {m[1]:.1f}, {m[2]:.1f} ({max(m[1], m[2]) / U10:.2f})")
    print(f"| {n} | " + " | ".join(cells) + " |")
