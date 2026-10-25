#!/usr/bin/env python3
"""Tolerance gate for air-cascade step 0 (docs/contracts/air-cascade.md, «Допуски сверки»).

Reads R2 result JSON files and prints one line per case plus the final line
`worst=<ratio>` — the largest of u_rel/1e-3, th_abs/0.05, |iters - iters_ref|/iters_tol
over all files (status other than "ok" -> worst=inf). Pass: worst <= 1.

    python3 tolerance.py out/flat_wind_release_t8.json ...            # ref/ cases: iters_tol = max(20, ref/10)
    python3 tolerance.py --iters-tol 20 out/ongudai_*_release_t8.json  # Ongudai: iters_tol = 20
"""
from __future__ import annotations

import argparse
import json
import math
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--iters-tol", type=int, default=None,
                    help="absolute iteration tolerance (default: max(20, iters_ref/10))")
    a = ap.parse_args()
    worst = 0.0
    for f in a.files:
        d = json.load(open(f))
        ref = int(d["iters_ref"])
        lim = a.iters_tol if a.iters_tol is not None else max(20, ref // 10)
        dev = d["dev"]
        r = max(dev["u_rel"] / 1e-3, dev["th_abs"] / 0.05, abs(int(d["iters"]) - ref) / lim)
        if d["status"] != "ok" or not math.isfinite(r):
            r = math.inf
        worst = max(worst, r)
        print(f"{d['case']}: status {d['status']}, iters {d['iters']}/{ref} (tol {lim}), "
              f"u_rel {dev['u_rel']:.3e}, th_abs {dev['th_abs']:.3e} K -> ratio {r:.3g}")
    print(f"worst={worst:.6g}" if math.isfinite(worst) else "worst=inf")
    return 0


if __name__ == "__main__":
    sys.exit(main())
