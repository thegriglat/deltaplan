"""k_sky: средняя hcc (ERA5, выборка ARCO: сутки 1 и 13 каждого месяца, 00+12 UTC) в дни категории облачности дня (tcc окна местных 10-16 ч, HH-1c,
clear<0.2, partly 0.2-0.6, overcast>0.6), делённая на среднюю hcc всех дней той же выборки. Суша (lsm>0.5), 0-75 |lat|, пояса и физические сезоны
как в td_sky.json, вес cos(lat). Годы 2011-2013 (пересечение). Выход hcc_sky.json. Запуск: python hcc_sky.py"""
import os, json, datetime as dt, numpy as np
R = os.path.expanduser("~/data/haze_humidity")
BANDS = [(0, 20), (20, 40), (40, 60), (60, 75)]; SEAS = ["DJF", "MAM", "JJA", "SON"]
LAT = -89.5 + np.arange(180)
LAND = np.load(R + "/climatology.npz")["lsm"] > 0.5
W = np.cos(np.radians(LAT))[:, None] * np.ones((1, 360))
band = np.full(180, -1)
for b, (lo, hi) in enumerate(BANDS): band[(abs(LAT) >= lo) & (abs(LAT) < hi)] = b
smap = np.array([0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 0])
S = np.zeros((4, 4, 3)); Wt = np.zeros((4, 4, 3)); SA = np.zeros((4, 4)); WA = np.zeros((4, 4)); N = np.zeros((4, 4, 3), int); NA = np.zeros((4, 4), int)
for y in (2011, 2012, 2013):
    tcc = np.load(f"{R}/td_sky/{y}.npz")["tcc"]
    for mo in range(1, 13):
        for d in (1, 13):
            f = f"{R}/upper_misc/{y}/{mo:02d}-{d:02d}.npz"
            if not os.path.exists(f): continue
            h = np.nan_to_num(np.load(f)["hcc"].astype(float), nan=0.0); t = tcc[(dt.date(y, mo, d) - dt.date(y, 1, 1)).days].astype(float)
            hh = np.load(f)["hcc"]; ok = np.isfinite(hh) & np.isfinite(t) & LAND
            cat = np.where(t < 0.2, 0, np.where(t <= 0.6, 1, 2))
            for b in range(4):
                rows = (band == b)[:, None] & ok
                # южное полушарие: физический сезон сдвинут на полгода
                for hem in (0, 1):
                    r = rows & ((LAT < 0)[:, None] == bool(hem))
                    s = (smap[(mo - 1 + 6 * hem) % 12])
                    w = W * r
                    SA[b, s] += (w * h).sum(); WA[b, s] += w.sum(); NA[b, s] += r.sum()
                    for c in range(3):
                        rc = r & (cat == c); wc = W * rc
                        S[b, s, c] += (wc * h).sum(); Wt[b, s, c] += wc.sum(); N[b, s, c] += rc.sum()
mean_all = SA / WA
k = {n: (S[:, :, c] / Wt[:, :, c] / mean_all).round(3).tolist() for c, n in enumerate(["clear", "partly", "overcast"])}
out = {"bands": BANDS, "seasons": SEAS, "k_sky": k, "hcc_mean_all": mean_all.round(4).tolist(),
       "n": {n: N[:, :, c].tolist() for c, n in enumerate(["clear", "partly", "overcast"])}, "n_all": NA.tolist(),
       "note": "n - клетко-дни (суша, 1°), не независимые; выборка ARCO: сутки 1 и 13 месяца, hcc = среднее 00+12 UTC против tcc окна 10-16 местных; 2011-2013; pooled по клеткам пояса (на клетку <30 дней)"}
json.dump(out, open(os.path.dirname(os.path.abspath(__file__)) + "/hcc_sky.json", "w"), ensure_ascii=False, indent=1)
for n in k: print(n, np.array(k[n]))
print("hcc всех", mean_all.round(3)); print("n clear min", N[:, :, 0].min())
