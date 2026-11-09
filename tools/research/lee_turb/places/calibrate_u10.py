"""Подбор U10 притока: скорость модели (dp-stand formula, MEAN) на опорной мачте = измеренной.

  python3 calibrate_u10.py [--iters 2]
Правило как в tools/research/cases (b1/u10.py): U10 × U_данных / S_модели на опорной точке (модель почти линейна по U10 в
нейтрали, поэтому 1–2 итерации). Опорные точки — extra.point_labels случая: tse04_100m (SW), tse13_100m (NE), RS_10m (Askervein).
Печатает новые u10 для CASES в make_cases.py (перезаписывать вручную: u10 — вход случая, не результат).
"""
import json
import math
import subprocess
import sys
import csv
from pathlib import Path

import make_cases as MC

HERE = Path(__file__).resolve().parent
REFS = {"perdigao_sw": ("tse04_100m", 8.8244), "perdigao_ne": ("tse13_100m", 8.791), "askervein_tu03b": ("RS_10m", 8.895)}


def model_speed(name):
    case = HERE / "cases" / f"{name}.json"
    place = MC.PLACES / f"{MC.CASES[name]['site']}.json"
    pr = subprocess.run(
        ["cargo", "run", "-q", "--release", "--manifest-path", str(MC.ROOT / "rust/Cargo.toml"), "-p", "dp-stand", "--",
         "sample", "--model", "formula", "--mode", "mean", "--timeout", "900", "--case", str(case), "--place", str(place)],
        capture_output=True, text=True, cwd=MC.ROOT)
    if pr.returncode:
        sys.exit(f"dp-stand: {pr.stderr[-500:]}")
    out = pr.stdout
    rows = list(csv.DictReader(out.splitlines()))
    labels = json.load(open(case))["extra"]["point_labels"]
    r = rows[labels.index(REFS[name][0])]
    return math.hypot(float(r["vx"]), float(r["vz"]))


if __name__ == "__main__":
    iters = int(sys.argv[sys.argv.index("--iters") + 1]) if "--iters" in sys.argv else 2
    for name, (lab, obs) in REFS.items():
        u10 = MC.CASES[name]["u10"]
        for it in range(iters):
            s = model_speed(name)
            print(f"{name} итерация {it}: u10 {u10:.3f}, модель {lab} {s:.3f} м/с, данные {obs}", flush=True)
            u10 *= obs / s
            MC.CASES[name]["u10"] = u10
            MC.main()
        print(f"{name}: u10 -> {u10:.3f}")
