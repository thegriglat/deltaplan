"""Градиент Tmax и суточной амплитуды по высоте: регрессия месячных средних TX/DTR (ERA5 0.25°) на высоту орографии ERA5
по 5x5 подклеткам 0.25° внутри каждой ячейки 1° (суша, перепад высот в ячейке >= 300 м). Пул по ячейкам региона
(сумма ковариаций / сумма дисперсий), по сезонам. Результат -> gradient.json (К/км, величина растёт с высотой >0, обычно <0).
Запуск: python gradient.py"""
import json, os
import numpy as np
from common import RAW

R = os.path.expanduser(RAW)
c = np.load(f"{R}/climatology_t.npz")
tx025 = c["tx025"]; dt025 = c["dtr025"]; z025 = c["z025"]; lsm025 = c["lsm025"]


def prep(a):  # (..., 721, 1440) lat 90->-90, lon 0.. -> lat -90..90, lon -180..
    a = np.roll(a, 720, axis=-1)
    return a[..., ::-1, :]


z = prep(z025); lsm = prep(lsm025)
la = (4 * np.arange(180)[:, None] + np.arange(5)[None, :])  # (180,5)
lo = ((4 * np.arange(360)[:, None] + np.arange(5)[None, :]) % 1440)  # (360,5)


def blocks(a):  # -> (..., 180, 360, 25)
    b = a[..., la[:, :, None, None], lo[None, None, :, :]]  # (...,180,5,360,5)
    b = np.moveaxis(b, -3, -2)  # (...,180,360,5,5)
    return b.reshape(b.shape[:-2] + (25,))


zb = blocks(z); lb = blocks(lsm)
land = lb.min(-1) > 0.9
zr = zb.max(-1) - zb.min(-1)
ok = land & (zr >= 300)
zc = zb - zb.mean(-1, keepdims=True)
var = (zc ** 2).sum(-1)[None] * np.ones((12, 1, 1))
COV = {}
for name, arr in (("tx", tx025), ("dtr", dt025)):
    tb = blocks(prep(arr)); tc = tb - tb.mean(-1, keepdims=True)
    COV[name] = (zc * tc).sum(-1)
lat = -89.5 + np.arange(180)[:, None] * np.ones((1, 360)); lon = -179.5 + np.arange(360)[None, :] * np.ones((180, 1))
regions = {
    "land_global": np.ones_like(lat, bool),
    "land_30_60N": (lat >= 30) & (lat <= 60),
    "land_tropics_20S_20N": np.abs(lat) <= 20,
    "altai_48_56N_80_92E": (lat >= 48) & (lat <= 56) & (lon >= 80) & (lon <= 92),
    "s_urals_52_56N_57_61E": (lat >= 51) & (lat <= 56) & (lon >= 56) & (lon <= 62),
    "crimea_44_46N_32_36E": (lat >= 44) & (lat <= 46) & (lon >= 32) & (lon <= 36),
    "iran_zagros_26_34N_44_56E": (lat >= 26) & (lat <= 34) & (lon >= 44) & (lon <= 56),
    "queensland_20_14S_142_147E": (lat >= -20) & (lat <= -14) & (lon >= 142) & (lon <= 147),
}
seasons = {"DJF": [11, 0, 1], "MAM": [2, 3, 4], "JJA": [5, 6, 7], "SON": [8, 9, 10], "year": list(range(12))}
res = {}
for vn, cov in COV.items():
    res[vn] = {}
    for rn, rm in regions.items():
        res[vn][rn] = {}
        for sn, ms in seasons.items():
            msk = np.broadcast_to(ok[None] & rm[None], (12, 180, 360))
            mm = np.zeros_like(msk); mm[ms] = True
            sel = msk & mm
            if sel.sum() < 5:
                res[vn][rn][sn] = None; continue
            per = 1000 * cov[sel] / var[sel]
            res[vn][rn][sn] = {"pooled_k_per_km": round(float(1000 * cov[sel].sum() / var[sel].sum()), 2), "median_k_per_km": round(float(np.median(per)), 2),
                               "p10": round(float(np.percentile(per, 10)), 2), "p90": round(float(np.percentile(per, 90)), 2), "n_cell_months": int(sel.sum())}
json.dump(res, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "gradient.json"), "w"), indent=1, ensure_ascii=False)
for vn, rr in res.items():
    for rn, v in rr.items():
        print(vn, rn, {k: (x["pooled_k_per_km"], x["median_k_per_km"], x["n_cell_months"]) if x else None for k, x in v.items()})
