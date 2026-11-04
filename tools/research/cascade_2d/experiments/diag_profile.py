"""CSD-4, механизм: профиль u(z) плоского случая C0 в одной колонне (x ~ 0) — эталон P25, B400, каскад V1 (от 400),
P400 на своих центрах. Печатает таблицу и пишет out/diag_C0_profile.json."""
import json, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); CD = os.path.join(HERE, "..")
sys.path.insert(0, os.path.join(CD, "metrics")); sys.path.insert(0, os.path.join(CD, "contract"))
import metrics as M, cascade2d_io as io
D = os.environ.get("CASCADE2D_DATA", os.path.expanduser("~/data/cascade_2d")) + "/fields/C0/"
rm, ra = io.read_f1(D + "picard_none_d25.json")
cm, ca = io.read_f1(D + "cascade_V1_d25_from400.json"); cm, ca = M.to_ref_grid(cm, ca, rm, ra)
bm, ba = io.read_f1(D + "picard_none_d400.json")
b4 = M.make_baseline(bm, ba, rm, ra)
bmeta, barr = b4
ur, _ = M.cell_vel(ra); uc, _ = M.cell_vel(ca); ub, _ = M.cell_vel(barr)
_, zc = M.centers(rm); xc, _ = M.centers(rm)
i = int(np.argmin(abs(xc)))
out = []
for k in range(1, 41):
    out.append(dict(z=float(zc[k] - ra["h"][i]), P25=float(ur[k, i]), B400=float(ub[k, i]), V1=float(uc[k, i])))
    if k % 2 == 1 or k < 8: print(f"z={out[-1]['z']:7.1f}  P25={ur[k,i]:.3f}  B400={ub[k,i]:.3f}  V1={uc[k,i]:.3f}")
cx, cz = M.centers(bm)
print("P400 центры z:", [round(float(z), 1) for z in cz[:5]], "u:", [round(float(v), 3) for v in M.cell_vel(ba)[0][:5, int(np.argmin(abs(cx)))]])
json.dump(out, open(os.path.join(CD, "out/diag_C0_profile.json"), "w"), indent=1)
