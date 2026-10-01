#!/usr/bin/env python3
"""air-start AS-1: итог out/passes.csv (passes_probe.gd) — остаток U над стартом по проходам и время.
Запуск: python3 passes_summary.py → out/passes_summary.md."""
import csv
import os
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")


def med(x):
    x = sorted(x)
    return x[len(x) // 2] if x else float("nan")


def main():
    rows = list(csv.DictReader(open(os.path.join(OUT, "passes.csv"))))
    g = defaultdict(list)
    for r in rows:
        g[(float(r["wind_set_ms"]), r["variant"])].append(r)
    L = ["# Подстройка притока по проходам (k₀ = 1; проход 2 — k·u10/U, дальше — секущая)", ""]
    L.append("Остаток |U10 над стартом / меню − 1| после прохода n (по 10 стартам: макс / медиана), стартов в ±10 %;")
    L.append("время — wall_s от начала загрузки (медиана / макс), одного прохода — медиана.")
    L.append("Время замерено при занятой машине (load average ~29 на 20 ядрах, GPU общий) — сравнивать проходы между собой.")
    L.append("")
    L.append("| ветер | вариант | проход | остаток макс / медиана, % | в ±10 % | в ±5 % | k мин…макс | wall_s медиана / макс | проход, с (медиана) | область, с | GPU области, с |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for (wv, var), rs in sorted(g.items()):
        by = defaultdict(list)
        for r in rs:
            by[int(r["pass"])].append(r)
        for p in sorted(by):
            q = by[p]
            res = [abs(float(r["ratio"]) - 1) * 100 for r in q]
            ks = [float(r["k"]) for r in q]
            ws = [float(r["wall_s"]) for r in q]
            L.append("| %g | %s | %d | %.1f / %.1f | %d из %d | %d | %.3f…%.3f | %.1f / %.1f | %.1f | %.1f | %.2f |" % (
                wv, var, p, max(res), med(res), sum(x <= 10 for x in res), len(q), sum(x <= 5 for x in res),
                min(ks), max(ks), med(ws), max(ws), med([float(r["pass_s"]) for r in q]),
                med([float(r["domain_s"]) for r in q]), med([float(r["domain_gpu_s"]) for r in q])))
    L.append("")
    L.append("## По стартам (вариант warm): U10/меню по проходам 1…4, k по проходам")
    L.append("")
    L.append("| ветер | старт | U/меню 1 / 2 / 3 / 4 | k 1 / 2 / 3 / 4 |")
    L.append("|---|---|---|---|")
    for (wv, var), rs in sorted(g.items()):
        if var != "warm":
            continue
        st = defaultdict(dict)
        for r in rs:
            st["%s/%s" % (r["location"], r["start"])][int(r["pass"])] = r
        for s, d in sorted(st.items()):
            L.append("| %g | %s | %s | %s |" % (
                wv, s, " / ".join("%.3f" % float(d[p]["ratio"]) for p in sorted(d)),
                " / ".join("%.3f" % float(d[p]["k"]) for p in sorted(d))))
    open(os.path.join(OUT, "passes_summary.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    main()
