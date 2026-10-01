"""AM-09: цена и следствия λ/h на сетках игры (Онгудай, 12:00, область 400 м → окна 100/50 м).

Итерации Пикара и время до критерия, ключевые числа (подъём у старта, ветер 50 м над стартом,
седловина) при λ/h = 0,1 (AM-01) и найденном значении.

  flock /tmp/heat_ca_gpu.lock .venv/bin/python cost_check.py 0.1 0.25   → out/cost_check.json
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "air3d"))

import air as A           # noqa: E402
import real as R          # noqa: E402
import ref_study as RS    # noqa: E402


def main():
    lfs = [float(a) for a in sys.argv[1:]] or [0.1, 0.25]
    out = []
    for hour in (12.0, 9.0):
        for U in (0.0, 3.0, 6.0):
            for lf in lfs:
                prm = A.Params(lam_frac=lf)
                D = RS.domain(400.0, hour, U, prm=prm)
                rd = RS.solve(D)
                W1 = RS.window(D, 100.0, hour, U, prm=prm)
                r1 = RS.solve(W1)
                W2 = RS.window(W1, 50.0, hour, U, prm=prm)
                r2 = RS.solve(W2)
                row = dict(hour=hour, U10=U, lam_frac=lf,
                           d400=dict(status=rd["status"], iters=rd["iters"], t=rd["t_solve"], key=R.key_numbers(D)),
                           w100=dict(status=r1["status"], iters=r1["iters"], t=r1["t_solve"], key=R.key_numbers(W1)),
                           w50=dict(status=r2["status"], iters=r2["iters"], t=r2["t_solve"], key=R.key_numbers(W2)))
                out.append(row)
                print(hour, U, lf, [(k, row[k]["status"], row[k]["iters"], row[k]["t"],
                                     round(row[k]["key"]["start_w200_max"], 2), round(row[k]["key"]["start_speed50"], 2))
                                    for k in ("d400", "w100", "w50")], flush=True)
                RS.free(W2, W1, D)
    (HERE / "out" / "cost_check.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
