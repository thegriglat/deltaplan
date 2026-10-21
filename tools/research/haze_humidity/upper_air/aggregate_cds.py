"""RAW/upper_air_cds/<год>.nc -> RAW/upper_air_climatology.npz (t, z по месяцам, 1°; без sd). НЕ ЗАПУСКАЛСЯ (нет данных CDS).
Среднее по годам и по двум срокам (00+12 UTC), затем осреднение 0.25° -> 1° (common.to_1deg). Далее: python bake.py."""
import glob, os
import numpy as np
import xarray as xr
from common import RAW, to_1deg

R = os.path.expanduser(RAW)
files = sorted(glob.glob(f"{R}/upper_air_cds/[12]*.nc"))
years = [int(os.path.basename(f)[:4]) for f in files]
T = np.zeros((12, 180, 360)); Z = np.zeros((12, 180, 360))
for f in files:
    d = xr.open_dataset(f)
    tm = d["t"].mean([v for v in d["t"].dims if v not in ("valid_time", "latitude", "longitude")]) if d["t"].ndim > 3 else d["t"]
    zm = d["z"].mean([v for v in d["z"].dims if v not in ("valid_time", "latitude", "longitude")]) if d["z"].ndim > 3 else d["z"]
    for m in range(12):
        T[m] += to_1deg(tm.isel(valid_time=m).sortby("latitude", ascending=False).values - 273.15) / len(files)
        Z[m] += to_1deg(zm.isel(valid_time=m).sortby("latitude", ascending=False).values / 9.80665) / len(files)
np.savez(f"{R}/upper_air_climatology.npz", t=T, z=Z, sd=np.zeros_like(T), years=np.array([years[0], years[-1]]))
print("T", T.min(), T.max(), "Z", Z.min(), Z.max(), "годы", years[0], years[-1])
