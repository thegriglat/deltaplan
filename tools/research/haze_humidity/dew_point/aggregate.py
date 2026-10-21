"""RAW/daily/*.npz -> climatology.npz: TD, SD (по месяцам, 1°), Z (1°), z025/lsm025 и средние по месяцам 0.25°.
Запуск: python aggregate.py"""
import os, glob, datetime as dt
import numpy as np
import zarr, gcsfs
from common import ARCO, RAW, to_1deg

R = os.path.expanduser(RAW)
files = sorted(glob.glob(f"{R}/daily/[12]*.npz"))
years = [int(os.path.basename(f)[:4]) for f in files]
print("годы", years[0], years[-1], len(years))
n = len(files)
s1 = np.zeros((12, 180, 360)); cnt = np.zeros(12)
msum = np.zeros((12, 721, 1440)); mcnt = np.zeros(12)
# проход 1: среднее по месяцам
for f, y in zip(files, years):
    d = np.load(f)
    td = d["td1"].astype(np.float64)
    mo = np.array([(dt.date(y, 1, 1) + dt.timedelta(k)).month - 1 for k in range(len(td))])
    for m in range(12):
        s1[m] += td[mo == m].sum(0); cnt[m] += (mo == m).sum()
    msum += d["msum025"]; mcnt += d["mcnt"]
mean = s1 / cnt[:, None, None]
# проход 2: sigma вокруг средней месяца по всем дням всех лет; и вне межгодовой части (вокруг среднего своего года-месяца)
ss = np.zeros((12, 180, 360)); ss_within = np.zeros((12, 180, 360))
for f, y in zip(files, years):
    td = np.load(f)["td1"].astype(np.float64)
    mo = np.array([(dt.date(y, 1, 1) + dt.timedelta(k)).month - 1 for k in range(len(td))])
    for m in range(12):
        x = td[mo == m]
        ss[m] += ((x - mean[m]) ** 2).sum(0)
        ss_within[m] += ((x - x.mean(0)) ** 2).sum(0)
sd = np.sqrt(ss / cnt[:, None, None])
sd_within = np.sqrt(ss_within / (cnt[:, None, None] - n))
# орография
fs = gcsfs.GCSFileSystem(token="anon")
g = zarr.open_consolidated(fs.get_mapper(ARCO), mode="r")
z025 = g["geopotential_at_surface"][0].astype(np.float64) / 9.80665
lsm025 = g["land_sea_mask"][0].astype(np.float64) if "land_sea_mask" in g else None
z1 = to_1deg(z025)
lsm1 = to_1deg(lsm025) if lsm025 is not None else None
np.savez(f"{R}/climatology.npz", td=mean, sd=sd, sd_within=sd_within, z=z1, lsm=lsm1, z025=z025, lsm025=lsm025,
         td025=msum / mcnt[:, None, None], years=np.array([years[0], years[-1]]), ndays=cnt)
print("td", mean.min(), mean.max(), "sd", sd.min(), sd.max(), "z", z1.min(), z1.max(), "lsm" , lsm025 is not None)
