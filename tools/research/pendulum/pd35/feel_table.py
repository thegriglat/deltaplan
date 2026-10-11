"""PD-35: таблица «до/после» по строкам FEEL (test_pendulum_flight_feel.gd): feel_table.py до.txt после.txt"""
import sys
def load(p):
    d = {}
    for l in open(p, encoding="utf-8"):
        if l.startswith("FEEL "):
            _, w, k, v = l.split()
            d[(w, k)] = float(v)
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
print("| крыло | метрика | до | после | Δ, % |\n|---|---|---|---|---|")
for k in a:
    x, y = a[k], b.get(k, float("nan"))
    d = (y - x) / abs(x) * 100 if abs(x) > 1e-6 else float("nan")
    print(f"| {k[0]} | {k[1]} | {x:.3f} | {y:.3f} | {d:+.1f} |")
