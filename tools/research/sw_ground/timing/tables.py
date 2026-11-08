"""Таблица SWG4 (метод × окно × стадия) из timing.json → markdown. tables.py <timing.json> > tables.md"""
import json
import sys

d = json.load(open(sys.argv[1]))
print(f"Машина: {d['machine']['cpu']} ({d['machine']['threads']} потоков), {d['machine']['gpu']}.\n")
print("| Метод | Окно, м | n_points | Стадия | Потоки | tol | t, с | Части, с |")
print("|---|---|---|---|---|---|---|---|")
order = {"panels": 0, "panels_rotor": 1, "picard": 2}
for r in sorted(d["rows"], key=lambda r: (order[r["method"]], r["window_dx"], r["stage"] != "cold", r["threads"] or 0, r["tol_scale"] or 0)):
    parts = ", ".join(f"{k} {v:.1f}" for k, v in r["parts"].items() if v >= 0.05)
    print(f"| {r['method']} | {r['window_dx']} | {r['n_points']} | {r['stage']} | {r['threads'] or '—'} | {r['tol_scale'] or '—'} | {r['t_total_s']:.1f} | {parts} |")
