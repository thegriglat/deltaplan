"""CSD-4, механизм: ошибка E_u, E_w по слоям над землёй (0-100, 100-300 м) для B400 (линейная интерполяция P400)
и каскада V1/V3 от 400 против P25; ROI M1 (|x-x_c| <= 3L), клетки воздуха. -> out/diag_bands.json"""
import json, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); CD = os.path.join(HERE, "..")
sys.path.insert(0, os.path.join(CD, "metrics")); sys.path.insert(0, os.path.join(CD, "contract"))
import metrics as M, cascade2d_io as io
DATA = os.environ.get("CASCADE2D_DATA", os.path.expanduser("~/data/cascade_2d")) + "/fields/"
res = {}
for C in ["C0", "C1", "C2", "C3", "C4"]:
    D = DATA + C + "/"
    rm, ra = io.read_f1(D + "picard_none_d25.json")
    xc0, L = M.case_xc_L(C)
    if xc0 is None:
        xc0, L = 0.0, 500.0
    U = M.u_ref_value(rm, ra)
    fl = {}
    bm, ba = io.read_f1(D + "picard_none_d400.json")
    b = M.make_baseline(bm, ba, rm, ra); fl["B400"] = b[1]
    for v in ("V1", "V3"):
        cm, ca = io.read_f1(D + f"cascade_{v}_d25_from400.json")
        fl[v] = M.to_ref_grid(cm, ca, rm, ra)[1]
    xs, _ = M.centers(rm); zag = M.z_agl(rm, ra)
    air = ra["cell"] > 0
    ur, wr = M.cell_vel(ra)
    res[C] = {}
    for name, a in fl.items():
        u, w = M.cell_vel(a)
        row = {}
        for lo, hi in ((0, 100), (100, 300)):
            msk = air & (zag > lo) & (zag <= hi) & (abs(xs[None, :] - xc0) <= 3 * L)
            row[f"{lo}-{hi}"] = dict(E_u=float(np.sqrt(np.mean((u[msk] - ur[msk]) ** 2)) / U),
                                    E_w=float(np.sqrt(np.mean((w[msk] - wr[msk]) ** 2)) / U))
        res[C][name] = row
    print(C, {n: {k: round(v["E_u"], 3) for k, v in r.items()} for n, r in res[C].items()})
json.dump(res, open(os.path.join(CD, "out/diag_bands.json"), "w"), indent=1)
