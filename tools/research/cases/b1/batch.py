"""Б1, этап 2: пачка калибровки — сетка (λ, α, z0) у каждого случая/подслучая, строка C10 на прогон.

λ = max(lam, λ/h·h): в нейтрали без нагрева h однородна (h = 0,3u*/f, u* = κU10/ln(10/z0)), и прогон определяется одним
числом λ — пачка идёт по λ (lam_frac = 0, lam = λ); совместная подгонка (fit.py) переводит общие (λ/h, lam) в λ случая
через h случая. Случаи независимы при общих параметрах: сетки считаются раздельно и совмещаются в χ².

  python batch.py plan                 — число прогонов и оценка времени по пробным (out/ctl_runs.jsonl)
  python batch.py run [ask|pd …]       — прогоны → out/runs_<case>.jsonl (продолжение с места)
"""
from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

OUT = HERE / "out"


def logspace(a, b, n):
    return [float(x) for x in np.exp(np.linspace(math.log(a), math.log(b), n))]


GRID = {
    "ask": dict(subs=["tu03b"], lam=logspace(10.0, 400.0, 9), alpha=list(np.linspace(0.19, 0.28, 7)),
                z0=logspace(0.01, 0.3, 5)),
    "pd": dict(subs=["ne", "sw"], lam=logspace(10.0, 400.0, 9), alpha=list(np.linspace(0.15, 0.33, 5)),
               z0=logspace(0.1, 1.0, 5)),
}


def points(case):
    g = GRID[case]
    return [(s, lam, float(a), z0) for s in g["subs"] for lam in g["lam"] for a in g["alpha"] for z0 in g["z0"]]


def key(sub, lam, a, z0):
    return (sub, round(lam, 4), round(a, 5), round(z0, 5))


def plan():
    ctl = [json.loads(line) for line in (OUT / "ctl_runs.jsonl").read_text().splitlines() if line.strip()]
    tot = 0.0
    for case in GRID:
        rows = [r for r in ctl if r["case"] == case and r["tag"].rsplit("_", 1)[1] in ("nom", "lamlo", "lamhi")
                and r["status"] == "ok"]
        w = float(np.mean([r["wall_total"] for r in rows]))
        n = len(points(case))
        tot += n * w
        print(f"{case}: {n} прогонов × {w:.1f} с (среднее nom/lamlo/lamhi) ≈ {n * w / 3600:.2f} ч")
    print(f"всего ≈ {tot / 3600:.2f} ч GPU (без ожидания замка)")


def run(cases):
    import askervein as AK
    import perdigao as PD
    mod = dict(ask=AK, pd=PD)
    for case in cases:
        f = OUT / f"runs_{case}.jsonl"
        done = set()
        if f.exists():
            for line in f.read_text().splitlines():
                r = json.loads(line)
                done.add(key(r["subcase"], r["params"]["lam"], r["params"]["alpha"], r["params"]["z0"]))
        pts = points(case)
        t0 = time.perf_counter()
        for i, (sub, lam, a, z0) in enumerate(pts):
            if key(sub, lam, a, z0) in done:
                continue
            r = mod[case].run_one(dict(lam_frac=0.0, lam=lam, alpha=a, z0=z0), sub)
            with open(f, "a") as fh:
                fh.write(json.dumps(r) + "\n")
            print(f"{case} {i + 1}/{len(pts)} {sub} λ={lam:.1f} α={a:.3f} z0={z0:.3f}: {r['status']} {r['iters']} it "
                  f"{r['t']:.1f} с ({time.perf_counter() - t0:.0f} с)", flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "plan":
        plan()
    else:
        run(sys.argv[2:] or list(GRID))
