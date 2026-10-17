"""Ветер у старта по уровням запечённых полей всех встроенных мест: горизонталь в первой воздушной клетке
и на ~10/50/100 м над землёй столбца старта (без лог-профиля; уровни — окно 50 м, окно 100 м, область 400 м).
python baked_levels.py > baked_levels.csv  (venv с numpy, zstandard)"""
import glob, json, os, sys
import numpy as np
from baked import load

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))

def col_at(g, a, x, y, agl):
    fi = (x - g["x0"]) / g["dx"] - 0.5; fj = (y - g["y0"]) / g["dx"] - 0.5
    i0, j0 = int(np.floor(fi)), int(np.floor(fj)); fx, fy = fi - i0, fj - j0
    out = np.zeros(4); wsum = 0
    for dj, di, w in ((0, 0, (1-fx)*(1-fy)), (0, 1, fx*(1-fy)), (1, 0, (1-fx)*fy), (1, 1, fx*fy)):
        i, j = i0 + di, j0 + dj
        hc = a["hc"][j, i]; nz = a["u"].shape[0]
        z = g["z_bot"] + (np.arange(nz) + 0.5) * g["dz"]
        k1 = int(np.argmax(z >= hc)); zt = max(hc + agl, z[k1])
        u = np.interp(zt, z[k1:], a["u"][k1:, j, i]); v = np.interp(zt, z[k1:], a["v"][k1:, j, i])
        wm = np.interp(zt, z[k1:], a["w_mech"][k1:, j, i]); wc = np.interp(zt, z[k1:], a["w_conv"][k1:, j, i])
        out += w * np.array([u, v, wm, wc]); wsum += w
    return out / wsum

print("location,site,wind_ms,from_deg,hour,sky,level_dx,agl_m,u,v,speed,w_mech,w_conv,inflow_k")
for js in sorted(glob.glob(os.path.join(ROOT, "data/locations/*/air/*.json"))):
    h, lv = load(js[:-5])
    k = h["key"]; w = k["weather"]; sx, sz = k["start"]; sy = -sz
    for g, m, a in lv:
        for agl in (10.0, 50.0, 100.0):
            u, v, wm, wc = col_at(g, a, sx, sy, agl)
            print(f"{k['location']},{k['site']},{w['wind_speed_ms']},{w['wind_from_deg']},{w['start_hour']},{w['sky']},{g['dx']:.0f},{agl:.0f},{u:.3f},{v:.3f},{np.hypot(u,v):.3f},{wm:.3f},{wc:.3f},{m.get('inflow_k')}")
