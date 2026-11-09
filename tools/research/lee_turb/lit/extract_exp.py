#!/usr/bin/env python3
"""Числа из открытых данных экспериментов (lit/data/, см. fetch_data.sh) -> derived_exp.json.
Запуск: python3 -I extract_exp.py   (numpy). Печатает сводку; build_lit.py читает derived_exp.json."""
import json, os
import numpy as np
H = os.path.dirname(os.path.abspath(__file__)); D = os.path.join(H, "data")
out = {}
# ---- Delville mixing layer (TMR delvilleshear): U_hi=41.54, U_lo=22.40, dU=19.14, x в мм
dU = 19.14; lam = dU / (41.54 + 22.40)
x, dw = np.loadtxt(os.path.join(D, "delville_exp_delomega.dat"), skiprows=2, unpack=True)
m = x >= 300
out["lam"] = lam
out["ddw_dx"] = float(np.polyfit(x[m], dw[m], 1)[0])
out["ddw_dx_seg"] = [float((dw[x == 650][0] - dw[x == 200][0]) / 450), float((dw[x == 1050][0] - dw[x == 650][0]) / 400)]
out["dw950"] = float(dw[x == 950][0])
z = None; T = {}
for l in open(os.path.join(D, "delville_exp_turb.dat")):
    if l.startswith("ZONE"): z = l.split('"')[1].replace(" ", ""); T[z] = []; continue
    p = l.split()
    if z and len(p) == 11: T[z].append([float(v) for v in p])
del_ = {}
for z, r in T.items():
    a = np.array(r); y = a[:, 2]
    k = 0.5 * (a[:, 6] + a[:, 8] + a[:, 10]); uv = -a[:, 4]
    half = y[uv > 0.5 * uv.max()]
    del_[z] = dict(su=float(np.sqrt(a[:, 6].max())), sv=float(np.sqrt(a[:, 8].max())), sw=float(np.sqrt(a[:, 10].max())),
                   uv=float(uv.max()), uv_y=float(y[uv.argmax()]), k=float(k.max()), k_y=float(y[k.argmax()]),
                   fwhm=float(half.max() - half.min()),
                   ruv=float(uv.max() / np.sqrt(a[uv.argmax(), 6] * a[uv.argmax(), 8])))
    if z == "x=950mm":
        s = np.sqrt(a[:, 6]); del_[z]["su_half"] = [float(np.interp(t, y, s) / s.max()) for t in (-0.5, 0.5)]
        del_[z]["su_one"] = [float(np.interp(t, y, s) / s.max()) for t in (-1.0, 1.0)]
out["delville"] = del_
# ---- Driver-Seegmiller step (TMR backstep): u/Uref, 1000*uu/Uref^2 ...
x, cf, _ = np.loadtxt(os.path.join(D, "cf.exp.dat"), skiprows=3, unpack=True)
i = np.where((cf[:-1] < 0) & (cf[1:] >= 0))[0][-1]
out["step_xr"] = float(x[i] - cf[i] * (x[i + 1] - x[i]) / (cf[i + 1] - cf[i])); out["step_xr_br"] = [float(x[i]), float(x[i + 1])]
z = None; P = {}
for l in open(os.path.join(D, "profiles.exp.dat")):
    if l.startswith("zone"): z = float(l.split('"')[1].split("=")[1]); P[z] = []; continue
    p = l.split()
    if z is not None and len(p) == 11:
        try: P[z].append([float(v) for v in p[1:]])
        except ValueError: pass
st = {}
for z, r in P.items():
    a = np.array(r); y, u, uu, vv, uv = a[:, 0], a[:, 1], a[:, 3] / 1000, a[:, 4] / 1000, a[:, 5] / 1000
    g = np.gradient(u, y); j = int(np.argmax(g)); dUl = float(u.max() - u.min())
    st[str(int(z))] = dict(su=float(np.sqrt(uu.max())), su_y=float(y[uu.argmax()]), sv=float(np.sqrt(vv.max())), sv_y=float(y[vv.argmax()]),
                           uv=float(-uv.min()), uv_y=float(y[uv.argmin()]), k2=float((0.5 * (uu + vv)).max()), umin=float(u.min()), umin_y=float(y[u.argmin()]),
                           umax=float(u.max()), dw=dUl / float(g[j]), dU=dUl)
out["step"] = st
# ---- periodic hill (Rapp & Manhart, KBwiki UFR 3-30): u_b, y/h от нижней плоскости
hill = {}
for Re in (10600, 37000):
    rows = {}
    for k, xh in enumerate([0.05, 0.5, 1, 2, 3, 4, 5, 6, 7, 8], 1):
        a = np.loadtxt(os.path.join(D, "hill", f"UFR3-30_X_{Re}_data_CR-{k:03d}.dat"), delimiter=",", comments="#")
        y, u, v, uu, vv, uv = a.T
        rows[str(xh)] = dict(su=float(np.sqrt(uu.max())), su_y=float(y[uu.argmax()]), sv=float(np.sqrt(vv.max())), uv=float(-uv.min()), uv_y=float(y[uv.argmin()]),
                             k2=float((0.5 * (uu + vv)).max()), u1=float(u[0]), y1=float(y[0]), umin=float(u.min()), umin_y=float(y[u.argmin()]))
    xs = [0.05, 0.5, 1, 2, 3, 4, 5, 6, 7, 8]; u1 = [rows[str(v)]["u1"] for v in xs]
    xr = None
    for q in range(2, len(xs) - 1):
        if u1[q] < 0 <= u1[q + 1]: xr = xs[q] + (0 - u1[q]) * (xs[q + 1] - xs[q]) / (u1[q + 1] - u1[q])
    hill[str(Re)] = dict(rows=rows, xr=xr)
out["hill"] = hill
json.dump(out, open(os.path.join(H, "derived_exp.json"), "w"), indent=1)
print(json.dumps({k: out[k] for k in ("lam", "ddw_dx", "ddw_dx_seg", "dw950", "step_xr", "step_xr_br")}))
print({r: hill[r]["xr"] for r in hill})
