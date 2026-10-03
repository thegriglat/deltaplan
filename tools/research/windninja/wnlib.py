"""Чтение выходов WindNinja и метрики сравнения (используют compare.py, analyze2.py)."""
import numpy as np
from common import *
from pilotnn.prep import tpi


def read_asc(p):
    with open(p) as f:
        hd = {}
        for _ in range(6):
            k, v = f.readline().split(); hd[k.lower()] = float(v)
    arr = np.loadtxt(p, skiprows=6)
    arr[arr == hd["nodata_value"]] = np.nan
    return arr[::-1], hd


def wn_uv(tag, dem, hgt, cid):
    d = WORK / "out" / tag / dem / hgt / cid
    u, hd = read_asc(next(d.glob("*_u.asc"))); v, _ = read_asc(next(d.glob("*_v.asc")))
    if abs(hd["cellsize"] * (u.shape[0] - 1) - 38400) < 1:     # 4.0: сетка узлов n+1 → значения в центрах клеток
        nodes = lambda x: 0.25 * (x[:-1, :-1] + x[1:, :-1] + x[:-1, 1:] + x[1:, 1:])
        u, v = nodes(u), nodes(v)
    n = u.shape[0]
    assert abs(hd["cellsize"] * n - 38400) < 1, (n, hd["cellsize"])
    k = n // 96
    blk = lambda x: x.reshape(96, k, 96, k).mean((1, 3)) if k > 1 else x
    return blk(u), blk(v)


def stats(u, v, ur, vr, hc, wdir, e=EDGE):
    s = (slice(e, -e), slice(e, -e))
    du, dv = (u - ur)[s], (v - vr)[s]
    d = np.hypot(du, dv)
    sp, spr = np.hypot(u, v)[s], np.hypot(ur, vr)[s]
    t = tpi(hc, 2000.0)[s]; rid = t >= np.percentile(t, RIDGE_PCT)
    # наветренная кромка: полоса из e клеток со стороны, откуда дует (wdir — «откуда»)
    ex, ey = -np.sin(np.radians(wdir)), -np.cos(np.radians(wdir))   # направление ветра (на восток, на север)
    full = np.hypot(u, v), np.hypot(ur, vr)
    def upwind(sp_full):
        m = np.zeros(sp_full.shape, bool)
        if abs(ex) > 0.38:
            if ex > 0: m[:, :e] = True       # ветер на восток — наветренная кромка западная
            else: m[:, -e:] = True
        if abs(ey) > 0.38:
            if ey > 0: m[:e, :] = True       # ветер на север — кромка южная (j = 0)
            else: m[-e:, :] = True
        return sp_full[m].mean()
    out = dict(
        med_dvec=float(np.median(d)), p90_dvec=float(np.percentile(d, 90)),
        bias_speed=float(np.mean(sp - spr)),                          # WN − решатель
        mean_speed_wn=float(sp.mean()), mean_speed_sol=float(spr.mean()),
        corr_speed=float(np.corrcoef(sp.ravel(), spr.ravel())[0, 1]),
        corr_u=float(np.corrcoef(u[s].ravel(), ur[s].ravel())[0, 1]),
        corr_v=float(np.corrcoef(v[s].ravel(), vr[s].ravel())[0, 1]),
        ridge_speed_wn=float(sp[rid].mean()), ridge_speed_sol=float(spr[rid].mean()),
        ridge_bias=float((sp[rid] - spr[rid]).mean()),
        ridge_ratio_wn=float(sp[rid].mean() / sp.mean()), ridge_ratio_sol=float(spr[rid].mean() / spr.mean()),
        ridge_dvec_med=float(np.median(d[rid])),
        up_speed_wn=float(upwind(full[0])), up_speed_sol=float(upwind(full[1])),
        # поворот направления: средний угол между векторами (°), клетки со скоростью решателя > 1 м/с
        dir_med_deg=float(np.median(np.degrees(np.abs(np.angle((u + 1j * v)[s] * np.conj((ur + 1j * vr)[s]))))[spr > 1.0])),
        struct_sol=float(np.median(np.hypot(ur[s] - ur[s].mean(), vr[s] - vr[s].mean()))),   # амплитуда структуры решателя
    )
    out.update(mean_over_up_wn=out["mean_speed_wn"] / out["up_speed_wn"], mean_over_up_sol=out["mean_speed_sol"] / out["up_speed_sol"],
               ridge_over_up_wn=out["ridge_speed_wn"] / out["up_speed_wn"], ridge_over_up_sol=out["ridge_speed_sol"] / out["up_speed_sol"],
               med_dvec_centered=float(np.median(np.hypot(du - du.mean(), dv - dv.mean()))))
    # знак отклонения по рельефу: подветренные/долины — клетки с tpi ≤ p10
    val = t <= np.percentile(t, 100 - RIDGE_PCT)
    out.update(valley_bias=float((sp[val] - spr[val]).mean()), valley_dvec_med=float(np.median(d[val])),
               valley_speed_wn=float(sp[val].mean()), valley_speed_sol=float(spr[val].mean()))
    return out


