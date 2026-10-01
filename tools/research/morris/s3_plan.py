"""План Морриса масштаба 3 (параметры configs/atmosphere.json, влияющие на ТКЭ у мачт Askervein).

  .venv/bin/python s3_plan.py → out/plan_s3.json (для turb_morris.gd) и out/plan_s3_meta.json
Готовые поля Askervein (AM-09б, вне git): ask_12p5_best, ask_25_best, ask_50a_best (λ/h 0,25, z0 0,042).
"""
from __future__ import annotations

import json
import math
from pathlib import Path

from SALib.sample import morris as MS

HERE = Path(__file__).resolve().parent
# ключ, вид, нижняя, верхняя, номинал
FACTORS3 = [
    ("turbulence.field_sigma_w_per_ustar", "lin", 1.0, 1.5, 1.25),
    ("turbulence.field_mixing_length_m", "log", 20.0, 80.0, 40.0),
    ("lee.field_deficit_attached", "lin", 0.0, 0.5, 0.3),
    ("lee.width", "lin", 0.2, 0.6, 0.4),                 # field_deficit_separated − attached
    ("lee.field_descent_slope", "log", 0.02, 0.1, 0.05),
    ("lee.field_sigma_u_per_du", "lin", 0.12, 0.24, 0.18),
    ("lee.field_sigma_w_per_du", "lin", 0.10, 0.18, 0.14),
]


def phys(u):
    v = {}
    for (k, kind, lo, hi, _), x in zip(FACTORS3, u):
        v[k] = math.exp(math.log(lo) + x * (math.log(hi) - math.log(lo))) if kind == "log" else lo + x * (hi - lo)
    over = {k: x for k, x in v.items() if k != "lee.width"}
    over["lee.field_deficit_separated"] = v["lee.field_deficit_attached"] + v["lee.width"]
    return v, over


def main(r=20, seed=1):
    pr = dict(num_vars=len(FACTORS3), names=[f[0] for f in FACTORS3], bounds=[[0.0, 1.0]] * len(FACTORS3))
    X = MS.sample(pr, N=100, num_levels=4, optimal_trajectories=r, seed=seed)
    k = len(FACTORS3)
    rows = []
    for i, u in enumerate(X):
        v, over = phys(u)
        rows.append(dict(id=f"q{i:03d}", traj=i // (k + 1), u=[float(x) for x in u], fx=v, over=over))
    (HERE / "out").mkdir(exist_ok=True)
    (HERE / "out" / "plan_s3.json").write_text(json.dumps([dict(id=r_["id"], over=r_["over"]) for r_ in rows]))
    (HERE / "out" / "plan_s3_meta.json").write_text(json.dumps(dict(problem=pr, levels=4, r=r, seed=seed,
                                                                    factors=FACTORS3, points=rows), ensure_ascii=False, indent=1))
    print(f"план масштаба 3: {len(rows)} точек ({r} × {k + 1})")


if __name__ == "__main__":
    main()
