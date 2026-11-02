"""Переход после разбега/отрыва при pitch 0 (trim_batch.gd --mode=launch): экстремумы за 1–21 с, огибающая V."""
import json, sys, math
import numpy as np
d = json.load(open(sys.argv[1]))
print(f"{'wing':20s}{'slope':>5s}{'t_lo':>6s}{'Vmin':>6s}{'Vmax':>6s}{'thmax':>6s}{'stall':>6s}{'A(1-11s)':>9s}{'A(30-40)':>9s}{'Vend':>6s}{'thend':>6s}")
for w, sl in d["wings"].items():
    for s, r in sl.items():
        a = np.array(r["series"]); t = a[:, 0]; V = a[:, 1]; th = a[:, 2]
        end = V[t > 30].mean()
        A1 = np.ptp(V[(t > 1) & (t < 11)]) / 2; A2 = np.ptp(V[t > 30]) / 2
        print(f"{w:20s}{s:>5s}{r['t_liftoff']:6.1f}{r['v_min_1_21']:6.1f}{r['v_max_1_21']:6.1f}{r['th_max_1_21']:6.1f}{r['stall_max']:6.2f}{A1:9.2f}{A2:9.2f}{end:6.1f}{th[t > 30].mean():6.1f}")
