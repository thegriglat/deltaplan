#!/usr/bin/env python3
"""SPF-1 п.1: отношение jitter(V_быстро)/jitter(V_трим) из out/jitter.json -> out/jitter_ratio.csv + печать."""
import csv, json, os
HERE = os.path.dirname(os.path.abspath(__file__))
d = json.load(open(os.path.join(HERE, "out", "jitter.json")))
g = d["gust"]
out = []
for wing, base in (("training", 32.3), ("sport", 35.4)):
    for L in (30.0, 100.0, 300.0):
        rows = [r for r in g if r["wing"] == wing and r["L"] == L]
        b = next(r for r in rows if r["v_target_kmh"] == base)
        for r in rows:
            if r is b:
                continue
            jr = r["jitter_mean"] / b["jitter_mean"]
            vr = r["v_ms"] / b["v_ms"]
            # по сидам: отношение при том же сиде
            per = [x["jitter"] / y["jitter"] for x, y in zip(r["rows"], b["rows"])]
            per.sort()
            out.append([wing, L, r["v_target_kmh"], round(b["v_ms"], 2), round(r["v_ms"], 2),
                        round(vr, 2), round(b["jitter_mean"], 4), round(r["jitter_mean"], 4),
                        round(jr, 2), round(per[0], 2), round(per[-1], 2), round(jr / vr, 2),
                        round(__import__("math").log(jr) / __import__("math").log(vr), 2)])
hdr = ["wing", "L_m", "V_kmh_target", "V_trim_meas_ms", "V_meas_ms", "V_ratio", "jit_trim", "jit_fast",
       "jit_ratio", "seed_min", "seed_max", "jit_ratio_per_V_ratio", "exponent_p(jit~V^p)"]
with open(os.path.join(HERE, "out", "jitter_ratio.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(hdr)
    w.writerows(out)
print("\t".join(hdr))
for r in out:
    print("\t".join(str(x) for x in r))
