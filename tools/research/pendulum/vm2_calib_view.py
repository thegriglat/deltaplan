#!/usr/bin/env python3
"""VM-2: просмотр out/vm2/calib.jsonl — по варианту параметров и крылу: Vmax с добором, усилие, отпускание."""
import json
import math
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent / "out" / "vm2"
rows = [json.loads(l) for l in (OUT / "calib.jsonl").read_text().splitlines() if l.strip()]
flt = sys.argv[1] if len(sys.argv) > 1 else ""
by = {}
for r in rows:
    if r.get("err"):
        print("ERR", r["key"], r["err"].splitlines()[-1])
        continue
    k = json.dumps({a: b for a, b in r["nl"].items()}, sort_keys=True)
    if flt and flt not in k:
        continue
    by.setdefault(k, []).append(r)
for k, rs in by.items():
    print(k)
    for r in sorted(rs, key=lambda x: x["wing"]):
        f = lambda x: "—" if x is None or (isinstance(x, float) and not math.isfinite(x)) else f"{x:.1f}"
        print(f"  {r['wing']:22s} V {f(r.get('full_V_kmh'))} ±{f(r.get('full_V_std_kmh'))} fx {f(r.get('full_fx_N'))} relx {f(r.get('full_rel_x'))} "
              f"α {f(r.get('full_alpha_deg'))} | отпуск θmin {f(r.get('rel_theta_min_deg'))} αmin {f(r.get('rel_alpha_min_deg'))} "
              f"αmax {f(r.get('rel_alpha_max_deg'))} Vend {f(r.get('rel_V_end_kmh'))} tuck {r.get('tuck')}")
