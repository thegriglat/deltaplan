"""CSD-4, V3h (справочно): сохраняет ли хеш среднее поле (СКО среднего по сидам 1-8 минус V3, в ROI, / U_ref)
и σ_u, σ_w по сидам (m/s) на z_agl = 25, 100, 300 м из out/metrics. -> out/diag_hash.json"""
import json, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); CD = os.path.join(HERE, "..")
sys.path.insert(0, os.path.join(CD, "metrics")); sys.path.insert(0, os.path.join(CD, "contract"))
import metrics as M, cascade2d_io as io
DATA = os.environ.get("CASCADE2D_DATA", os.path.expanduser("~/data/cascade_2d"))
res = {}
for C in ["C0", "C1", "C2", "C3", "C4"]:
    rm, ra = io.read_f1(f"{DATA}/fields/{C}/picard_none_d25.json")
    xc0, L = M.case_xc_L(C); U = M.u_ref_value(rm, ra)
    us = []
    for p in [f"{DATA}/fields/{C}/cascade_V3h_d25_from400.json"] + [f"{DATA}/fields_seeds/s{S}/{C}/cascade_V3h_d25_from400.json" for S in range(2, 9)]:
        m, a = io.read_f1(p); us.append(M.cell_vel(M.to_ref_grid(m, a, rm, ra)[1])[0:2])
    m, a = io.read_f1(f"{DATA}/fields/{C}/cascade_V3_d25_from400.json"); v3 = M.cell_vel(M.to_ref_grid(m, a, rm, ra)[1])
    xs, _ = M.centers(rm); zag = M.z_agl(rm, ra)
    roi = (ra["cell"] > 0) & (zag > 0) & (zag <= 300) & (abs(xs[None, :] - xc0) <= 3 * L)
    mean_u = np.mean([u[0] for u in us], axis=0); mean_w = np.mean([u[1] for u in us], axis=0)
    rows = json.load(open(os.path.join(CD, f"out/metrics/{C}.json")))["rows"]
    r = next(r for r in rows if r["variant"] == "V3h" and r["seed"] == 1 and r["parent_dx"] == 400 and r["dx"] == 25)
    res[C] = dict(mean_shift_u=float(np.sqrt(np.mean((mean_u[roi] - v3[0][roi]) ** 2)) / U),
                  mean_shift_w=float(np.sqrt(np.mean((mean_w[roi] - v3[1][roi]) ** 2)) / U),
                  sigma_u={z: r["sigma_u"][i] for z, i in ((25, 0), (100, 3), (300, 11))},
                  sigma_w={z: r["sigma_w"][i] for z, i in ((25, 0), (100, 3), (300, 11))})
    print(C, res[C])
json.dump(res, open(os.path.join(CD, "out/diag_hash.json"), "w"), indent=1)
