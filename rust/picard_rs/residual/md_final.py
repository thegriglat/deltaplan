"""PR-12: markdown tables for out/final/README.md from out/final/summary.json. python3 md_final.py [summary.json]"""
import json
import sys
from pathlib import Path

p = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "out/final/summary.json"
d = json.loads(p.read_text())
T = ["2", "3", "6", "8"]


def f(x, n=1):
    return "—" if x is None else f"{x:.{n}f}".replace(".", ",")


print("### До/после: полный solve, с (PR-1 tol 1 → итог tol 1 → итог tol 5)\n")
print("| случай | итераций (до / tol 1 / tol 5) | " + " | ".join(f"{t} пот." for t in T) + " |\n|---|---|" + "---|" * 4)
for c, v in d["before_after"].items():
    r8 = v["8"]
    it = f"{r8['base_iters'] or r8['iters']} / {r8['iters']} / {r8['iters_tol5']}"
    print(f"| {c} | {it} | " + " | ".join(f"{f(v[t]['base_total_s'])} → {f(v[t]['tol1_total_s'])} → **{f(v[t]['tol5_total_s'])}**" for t in T) + " |")
print("\n### мс/итерацию: PR-1 → итог (tol 1)\n")
print("| случай | " + " | ".join(f"{t} пот." for t in T) + " |\n|---|" + "---|" * 4)
for c, v in d["before_after"].items():
    print(f"| {c} | " + " | ".join(f"{f(v[t]['base_ms_per_iter'])} → {f(v[t]['ms_per_iter'])}" for t in T) + " |")
print("\n### Загрузка места (холодный), с (итерации): tol 5 | tol 1\n")
print("| случай | " + " | ".join(f"{t} пот." for t in T) + " |\n|---|" + "---|" * 4)
for c, v in d["table_cold"].items():
    print(f"| {c} | " + " | ".join(f"{f(v[t]['tol5']['total_s'])} ({v[t]['tol5']['iters']}) \\| {f(v[t]['tol1']['total_s'])} ({v[t]['tol1']['iters']})" for t in T) + " |")
print("\n### Тёплый пересчёт против холодного, с (итерации); доля срока при ×1 / ×10 / ×60\n")
for h, hv in d["table_warm"].items():
    for x, xv in hv.items():
        print(f"\n{h}, {x.replace('tol', 'tol_scale ')}\n")
        print("| потоков | тёплый | холодный | тёплый/холодный (время) | доля срока ×1 / ×10 / ×60 |\n|---|---|---|---|---|")
        for t in T:
            r = xv[t]
            sh = r["share_of_recompute_period"]
            print(f"| {t} | {f(r['warm']['total_s'], 2)} ({r['warm']['iters']}) | {f(r['cold']['total_s'])} ({r['cold']['iters']}) | {f(r['total_s_ratio'], 3)} | "
                  f"{f(100 * sh['1'], 2)} % / {f(100 * sh['10'], 1)} % / {f(100 * sh['60'], 0)} % |")
print("\n### Отклонение от холодного сошедшегося (tol 1) того же времени, м/с (max по клеткам)\n")
print("| конец | старт Δw | старт Δ(u,v) | склоны Δw | склоны Δwt | термики Δw | вся область Δw |\n|---|---|---|---|---|---|---|")
for h, hv in d["chain"]["series"].items():
    for l, s in hv.items():
        dv = s["dev"]
        print(f"| {h} {l} | " + " | ".join(f(dv[k][m], 3) for k, m in [("launch", "dw_max"), ("launch", "du_max"), ("slopes", "dw_max"), ("slopes", "dwt_max"), ("thermals", "dw_max"), ("domain", "dw_max")]) + " |")
