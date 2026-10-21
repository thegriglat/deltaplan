"""RAW/upper_air/<год>.npz -> climatology.npz (T, Z по месяцам, 1°) и t700_sd.npz (σ среднесуточной T700, float16, ключ sd_k).
σ — вокруг средней своего месяца по всем дням всех лет (включает межгодовую часть), как в HH-1. Запуск: python aggregate.py"""
import os, glob, datetime as dt
import numpy as np
from common import RAW

R = os.path.expanduser(RAW)
files = sorted(glob.glob(f"{R}/upper_air/[12]*.npz"))
files = [f for f in files if not f.endswith(".tmp.npz")]
years = [int(os.path.basename(f)[:4]) for f in files]
print("годы", years[0], years[-1], len(years))


def months(y, n):
    return np.array([(dt.date(y, 1, 1) + dt.timedelta(k)).month - 1 for k in range(n)])


st = np.zeros((12, 180, 360)); sz = np.zeros((12, 180, 360)); cnt = np.zeros(12)
for f, y in zip(files, years):
    d = np.load(f)
    t, z = d["t1"].astype(np.float64), d["z1"].astype(np.float64)
    mo = months(y, len(t))
    mo[np.isnan(t).all((1, 2))] = -1
    for m in range(12):
        st[m] += t[mo == m].sum(0); sz[m] += z[mo == m].sum(0); cnt[m] += (mo == m).sum()
T = st / cnt[:, None, None]; Z = sz / cnt[:, None, None]
ss = np.zeros((12, 180, 360))
for f, y in zip(files, years):
    t = np.load(f)["t1"].astype(np.float64)
    mo = months(y, len(t))
    mo[np.isnan(t).all((1, 2))] = -1
    for m in range(12):
        ss[m] += ((t[mo == m] - T[m]) ** 2).sum(0)
sd = np.sqrt(ss / cnt[:, None, None])
assert not np.isnan(T).any() and not np.isnan(Z).any()
np.savez(f"{R}/upper_air_climatology.npz", t=T, z=Z, sd=sd, years=np.array([years[0], years[-1]]), ndays=cnt)
here = os.path.dirname(os.path.abspath(__file__))
np.savez_compressed(f"{here}/t700_sd.npz", sd_k=sd.astype(np.float16))
print("T", T.min(), T.max(), "Z", Z.min(), Z.max(), "sd", sd.min(), sd.max(), "дней", cnt.min(), cnt.max())
