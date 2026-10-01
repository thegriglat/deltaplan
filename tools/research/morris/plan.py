"""План Морриса: оптимизированные траектории (Campolongo et al. 2007) по 16 факторам, уровни p = 4.

  .venv/bin/python plan.py --r 10 --seed 1 → out/plan.json
Точка «nom» — номинал (значения Params после AM-09 и номинальные z0/alpha случаев) для отсчёта.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from SALib.sample import morris as MS

import model as M

HERE = Path(__file__).resolve().parent


def problem():
    return dict(num_vars=len(M.FACTORS), names=M.NAMES, bounds=[[0.0, 1.0]] * len(M.FACTORS))


def nominal_u():
    """Номинал в [0, 1] (для категорий — середина своего интервала)."""
    import math
    u = []
    for f in M.FACTORS:
        if f["kind"] == "log":
            u.append((math.log(f["nom"]) - math.log(f["lo"])) / (math.log(f["hi"]) - math.log(f["lo"])))
        elif f["kind"] == "lin":
            u.append((f["nom"] - f["lo"]) / (f["hi"] - f["lo"]))
        else:
            n = len(f["levels"])
            u.append((f["levels"].index(f["nom"]) + 0.5) / n)
    return u


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--r", type=int, default=10)
    ap.add_argument("--levels", type=int, default=4)
    ap.add_argument("--cand", type=int, default=100, help="кандидатов для отбора траекторий")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default=str(HERE / "out" / "plan.json"))
    a = ap.parse_args()
    pr = problem()
    X = MS.sample(pr, N=a.cand, num_levels=a.levels, optimal_trajectories=a.r, seed=a.seed)
    k = pr["num_vars"]
    rows = [dict(id="nom", traj=-1, u=nominal_u(), fx=M.to_phys(nominal_u()))]
    for i, u in enumerate(X):
        rows.append(dict(id=f"p{i:03d}", traj=i // (k + 1), u=[float(x) for x in u], fx=M.to_phys(u)))
    plan = dict(problem=pr, levels=a.levels, r=a.r, cand=a.cand, seed=a.seed, factors=M.FACTORS, points=rows)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(plan, ensure_ascii=False, indent=1))
    print(f"план: {len(X)} точек ({a.r} траекторий × {k + 1}) + номинал → {a.out}")


if __name__ == "__main__":
    main()
