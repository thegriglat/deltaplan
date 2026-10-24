#!/usr/bin/env python3
"""Markdown tables for the README: out/base/ (PR-1, R2 v2) and timer overhead against out/mv/ (AC-R4)."""
import glob, json, os

d = os.path.dirname(os.path.abspath(__file__))
mv = os.path.join(os.path.dirname(d), "mv")
rs = {}
for f in glob.glob(os.path.join(d, "ongudai_d400_*_release_t*.json")):
    r = json.load(open(f))
    rs[(r["case"].replace("ongudai_d400_", ""), r["threads"])] = r
cases = ["u3_heat", "u3_mech", "u0_heat", "u6_heat"]
tt = [2, 3, 6, 8, 18]
cell = lambda c, t, f: f(rs[(c, t)]) if (c, t) in rs else "-"

print("### мс/итерацию\n")
print("| случай | итераций | " + " | ".join(f"{t} пот." for t in tt) + " |")
print("|---|---|" + "---|" * len(tt))
for c in cases:
    print(f"| {c} | {rs[(c, 8)]['iters']}/{rs[(c, 8)]['iters_ref']} | " + " | ".join(
        cell(c, t, lambda r: f"{r['time']['ms_per_iter']:.1f}") for t in tt) + " |")

print("\n### Полное время solve, с\n")
print("| случай | " + " | ".join(f"{t} пот." for t in tt) + " |")
print("|---|" + "---|" * len(tt))
for c in cases:
    print(f"| {c} | " + " | ".join(cell(c, t, lambda r: f"{r['time']['total_s']:.2f}") for t in tt) + " |")

print("\n### Фазы итерации, мс (доля), u3_heat\n")
ph = ["mom", "heat", "proj", "kupd", "other"]
print("| потоков | " + " | ".join(ph) + " | всего |")
print("|---|" + "---|" * (len(ph) + 1))
for t in tt:
    if ("u3_heat", t) not in rs:
        continue
    r = rs[("u3_heat", t)]["time"]
    print(f"| {t} | " + " | ".join(f"{r['phase_ms'][p]:.1f} ({r['phase_ms'][p] / r['ms_per_iter'] * 100:.0f} %)" for p in ph)
          + f" | {r['ms_per_iter']:.1f} |")

print("\n### Фазы по случаям, 8 потоков, мс (доля)\n")
print("| случай | " + " | ".join(ph) + " | всего |")
print("|---|" + "---|" * (len(ph) + 1))
for c in cases:
    r = rs[(c, 8)]["time"]
    print(f"| {c} | " + " | ".join(f"{r['phase_ms'][p]:.1f} ({r['phase_ms'][p] / r['ms_per_iter'] * 100:.0f} %)" for p in ph)
          + f" | {r['ms_per_iter']:.1f} |")

m = os.path.join(mv, "ongudai_d400_u3_heat_release_t8.json")
if os.path.exists(m):
    a = json.load(open(m))["time"]["ms_per_iter"]
    b = rs[("u3_heat", 8)]["time"]["ms_per_iter"]
    print(f"\nНакладные таймера: u3_heat 8 потоков {b:.1f} мс/ит против AC-R4 {a:.1f} -> {(b / a - 1) * 100:+.1f} %")
