"""Скорость на 60 м относительно притока (кромка) по классам рельефа: гребень, долина, наветренный/подветренный склон.
python classes.py → out/classes.md (WN 3.13, DEM 400 м, трава)"""
import json
import numpy as np
from common import *
from wnlib import *
from scipy import ndimage
cases = json.load(open(OUT / "cases.json"))["cases"]
acc = {}
e = EDGE
for c in cases:
    z = np.load(OUT / f"ref_{c['id']}.npz"); hc = z["hc"]
    u, v = wn_uv("mass", "d400", "60", c["id"]); ur, vr = z["u60"], z["v60"]
    ex, ey = -np.sin(np.radians(c["wdir"])), -np.cos(np.radians(c["wdir"]))
    sw, ss = np.hypot(u, v), np.hypot(ur, vr)
    gy, gx = np.gradient(ndimage.gaussian_filter(hc, 1.0), 400.0)
    al = (gx * ex + gy * ey)                        # >0 — склон поднимается по ветру (наветренный)
    t = tpi(hc, 2000.0)
    s = (slice(e, -e), slice(e, -e))
    # кромка: как в compare
    m = np.zeros(hc.shape, bool)
    if abs(ex) > .38:
        if ex > 0: m[:, :e] = True
        else: m[:, -e:] = True
    if abs(ey) > .38:
        if ey > 0: m[:e, :] = True
        else: m[-e:, :] = True
    upw, ups = sw[m].mean(), ss[m].mean()
    tt = t[s]; aa = al[s]
    cl = {"гребень (tpi ≥ p90)": tt >= np.percentile(tt, 90), "долина (tpi ≤ p10)": tt <= np.percentile(tt, 10),
          "наветренный склон (∇h·ê > 0,15)": aa > 0.15, "подветренный склон (∇h·ê < −0,15)": aa < -0.15,
          "ровное (|∇h| < 0,05)": np.hypot(gx, gy)[s] < 0.05}
    for k, mk in cl.items():
        if mk.sum() < 5: continue
        acc.setdefault(k, []).append((sw[s][mk].mean() / upw, ss[s][mk].mean() / ups, mk.mean()))
md = ["| класс клеток | n случаев | доля клеток | скорость/приток WN | скорость/приток решатель | разность (WN − реш.) |", "|---|---|---|---|---|---|"]
for k, l in acc.items():
    a = np.array(l)
    md.append(f"| {k} | {len(a)} | {np.median(a[:,2]):.2f} | {np.median(a[:,0]):.2f} | {np.median(a[:,1]):.2f} | {np.median(a[:,0]-a[:,1]):+.2f} |")
(OUT / "classes.md").write_text("\n".join(md) + "\n"); print("\n".join(md))
