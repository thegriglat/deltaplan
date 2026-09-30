#!/usr/bin/env python3
"""Сводка tools/flight/wing_clearance_run.tscn: худшее крыло по (старт, фаза), до/после.

python3 tools/flight/wing_clearance_table.py build/sf4/before.csv [build/sf4/after.csv]
"""
import csv
import sys
from collections import defaultdict


def load(path):
    d = defaultdict(list)
    for r in csv.DictReader(open(path)):
        d[(r["scene"], r["phase"])].append(r)
    return d


def worst(rows):
    return min(rows, key=lambda r: float(r["clear_min"]))


def fmt(r):
    return "%5.1f | %5.1f | %5.2f %-5s %-12s" % (
        float(r["bank_deg"]), float(r["theta_deg"]), float(r["clear_min"]), r["part"], r["wing"])


before = load(sys.argv[1])
after = load(sys.argv[2]) if len(sys.argv) > 2 else {}
print("| старт | фаза | уклон по курсу/поперёк, ° | до: крен | тангаж | зазор, м (часть, крыло) "
      "| без крена | вокруг HangPoint | по рисуемой сетке | после: крен | тангаж | зазор |")
print("|" + "---|" * 12)
for k, rows in before.items():
    w = worst(rows)
    nb = min(float(r["clear_nobank"]) for r in rows)
    ph = min(float(r["clear_pivot_hang"]) for r in rows)
    rr = [float(r["clear_rendered"]) for r in rows if r["clear_rendered"] != "nan"]
    rend = "%.2f" % min(rr) if rr else "—"
    a = "— | — | —"
    if k in after:
        aw = worst(after[k])
        a = "%.1f | %.1f | %.2f %s %s" % (float(aw["bank_deg"]), float(aw["theta_deg"]),
                                          float(aw["clear_min"]), aw["part"], aw["wing"])
    print("| %s | %s | %.0f / %.0f | %.1f | %.1f | %.2f %s %s | %.2f | %.2f | %s | %s |" % (
        k[0], k[1], float(w["slope_along_deg"]), float(w["slope_cross_deg"]),
        float(w["bank_deg"]), float(w["theta_deg"]), float(w["clear_min"]), w["part"], w["wing"],
        nb, ph, rend, a))
