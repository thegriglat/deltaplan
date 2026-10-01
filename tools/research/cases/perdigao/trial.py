"""Пробный прогон А4 (проверка постановки, НЕ калибровка): оба подслучая на номинале перекалибровки
(λ/h 0,031, α 0,235, z0 леса 0,645 м, прочее Params()), соседние dx (оценка sig_grid), чувствительность к
z0 / смещению под пологом / λ/h — чтобы видеть, что наблюдаемые откликаются на параметры.

  python trial.py        → out/trial_runs.jsonl (строки C10 + tag), out/grid_sigma.json
Продолжение с места: готовые (tag, subcase) пропускаются.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import perdigao as P                     # noqa: E402

OUT = HERE / "out"
RUNS = [  # tag, over, dx, d_disp
    ("nom30", {}, 30.0, P.D_DISP),
    ("nom20", {}, 20.0, P.D_DISP),
    ("nom40", {}, 40.0, P.D_DISP),
    ("z0_0.1", {"z0": 0.1}, 30.0, P.D_DISP),
    ("z0_1.8", {"z0": 1.8}, 30.0, P.D_DISP),
    ("d0", {}, 30.0, 0.0),
    ("lam0.25", {"lam_frac": 0.25}, 30.0, P.D_DISP),
]


def main():
    OUT.mkdir(exist_ok=True)
    f = OUT / "trial_runs.jsonl"
    done = set()
    if f.exists():
        for line in f.read_text().splitlines():
            r = json.loads(line)
            done.add((r["tag"], r["subcase"]))
    t0 = time.perf_counter()
    for tag, over, dx, d in RUNS:
        for sub in P.SUBCASES:
            if (tag, sub) in done:
                continue
            P.D_DISP = d
            t1 = time.perf_counter()
            r = P.run_one(over, sub, dx)
            r["tag"] = tag
            r["d_disp"] = d
            r["wall_total"] = round(time.perf_counter() - t1, 1)
            with open(f, "a") as fh:
                fh.write(json.dumps(r) + "\n")
            print(f"{tag} {sub} dx={dx:g}: {r['status']} {r['iters']} it, решатель {r['t']:.1f} с, всего {r['wall_total']} с "
                  f"({time.perf_counter() - t0:.0f} с)", flush=True)
    P.D_DISP = 0.7 * P.H_CANOPY
    # sig_grid = |obs(30) − obs(20)|
    rows = {(json.loads(l)["tag"], json.loads(l)["subcase"]): json.loads(l) for l in f.read_text().splitlines()}
    gs = {}
    for sub in P.SUBCASES:
        a, b = rows.get(("nom30", sub)), rows.get(("nom20", sub))
        if a and b and a["status"] == "ok" and b["status"] == "ok":
            for k, v in a["obs"].items():
                w = b["obs"].get(k)
                if v is not None and w is not None:
                    gs[k] = abs(v - w)
    (OUT / "grid_sigma.json").write_text(json.dumps(gs, indent=1, sort_keys=True))


if __name__ == "__main__":
    main()
