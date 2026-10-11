"""PD-19: разбор срыва полос в болтанке и после пикирования (прототип GameSim).

  python tools/research/pendulum/pd19_diag.py turb sport [--dt 120] [--variant base]
  python tools/research/pendulum/pd19_diag.py dive sport [--pull 1.0]
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import export_reference as X  # noqa: E402
from pendulum.model import Control  # noqa: E402
from pendulum.scenarios import BankHold  # noqa: E402

REF = json.loads((X.ROOT / "tests/flight/pendulum/reference.json").read_text())
D = math.degrees


def turb(w, dt, T=40.0):
    s = X.make(w, REF["blocks"][w], dt=dt)
    s.air_fn = X.turbulence_fn(REF["turbulence"])
    a_st = s.cl_max_strip / s.p.lift_slope
    hold = BankHold(0.0, kp=1.5, kd=0.8, ki=0.3)
    o = s.observe()
    rows = []
    t0 = time.time()
    for i in range(int(round(T / dt))):
        s.step(hold(0.0, o))
        o = s.observe()
        info = s._last_info
        arel = info["a"] - s.alpha0_root
        rows.append((o["t"], D(o["phi"]), D(o["theta"]), D(o["alpha"]), o["V"] * 3.6,
                     info["blend"].copy(), np.degrees(arel - a_st), o["rel_y"]))
        if not np.isfinite(o["phi"]):
            break
    print(f"{w} dt 1/{round(1/dt)}: {time.time()-t0:.1f} с счёта; a_st полосы {D(a_st):.1f}° (от нулевой), alpha0_root {D(s.alpha0_root):.1f}°, cl_max полосы {s.cl_max_strip:.3f}")
    return s, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("wing")
    ap.add_argument("--dt", type=int, default=120)
    a = ap.parse_args()
    if a.cmd == "turb":
        s, rows = turb(a.wing, 1 / a.dt)
        n = len(rows[0][5])
        # когда и какие полосы срываются
        first = None
        cnt = np.zeros(n)
        for r in rows:
            b = r[5] > 0.01
            cnt += b
            if first is None and b.any():
                first = r
        print("доля времени в срыве по полосам (0..7 правая корень→конец, 8..15 левая):")
        print(" ".join(f"{c/len(rows):.3f}" for c in cnt))
        mx = max(rows, key=lambda r: abs(r[1]))
        print(f"макс |крен| {mx[1]:.1f}° при t {mx[0]:.2f}")
        # хронология раз в 0,25 с вокруг первого срыва и до максимума крена
        for r in rows[:: max(1, a.dt // 4)]:
            b = r[5]
            print(f"t {r[0]:5.2f} φ {r[1]:7.1f} θ {r[2]:6.1f} α {r[3]:6.1f} V {r[4]:5.1f} ry {r[7]:+.2f} "
                  f"Δα до срыва R[{' '.join(f'{x:+3.0f}' for x in r[6][:8])}] L[{' '.join(f'{x:+3.0f}' for x in r[6][8:])}]")


if __name__ == "__main__":
    main()
