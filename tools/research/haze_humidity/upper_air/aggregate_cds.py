"""RAW/upper_air_cds/<год>.nc (месячные по часам суток, 1°-узлы 181x360) + RAW/upper_air_cds_daily/<год>.nc (суточные средние T700)
-> RAW/upper_air_climatology.npz (t °C, z м, sd K; 12x180x360, j=0 юг, i=0 -179.5°) и t700_sd.npz (sd_k float16).
Ячейка 1° = среднее 4 соседних узлов сетки 1° (узлы на целых градусах -> центры ячеек на полуградусах).
T, Z: среднее по годам и по сроками 00+12 UTC. σ: стандартное отклонение суточной T700 (daily_mean) вокруг среднего месяца
по всем дням всех лет (вклад межгодовой разницы месячных средних включён)."""
import glob, os
import numpy as np
import xarray as xr
from common import RAW

R = os.path.expanduser(RAW); H = os.path.dirname(os.path.abspath(__file__))


def tname(ds):
    return "valid_time" if "valid_time" in ds.coords else "time"


def nodes(da):
    """-> (..., 181, 360) lat -90..90 (юг первым), lon -180..179 по узлам."""
    da = da.sortby("latitude")
    lon = ((da["longitude"].values + 180) % 360) - 180
    da = da.assign_coords(longitude=lon).sortby("longitude")
    assert da.sizes["latitude"] == 181 and da.sizes["longitude"] == 360, da.sizes
    return da


def cells(a):
    """a (..., 181, 360) узлы lat=-90+j, lon=-180+i -> ячейки (..., 180, 360) с центрами -89.5+j, -179.5+i."""
    a = np.asarray(a, np.float64)
    ae = (a + np.roll(a, -1, axis=-1)) / 2  # восток (ячейка i между узлами i и i+1)
    return (ae[..., :-1, :] + ae[..., 1:, :]) / 2


def squeeze(da):
    for d in list(da.dims):
        if d not in (tname(da.to_dataset(name="x")), "latitude", "longitude") and da.sizes[d] == 1:
            da = da.isel({d: 0})
    return da


d = xr.open_dataset(f"{R}/upper_air_cds/2011_2020.nc"); tn = tname(d)
mon = d[tn].values.astype("datetime64[M]").astype(int) % 12
yrs = d[tn].values.astype("datetime64[Y]").astype(int) + 1970
years = [int(yrs.min()), int(yrs.max())]
files = [0]
T = np.zeros((12, 180, 360)); Z = np.zeros_like(T)
for name, acc, conv in (("t", T, lambda x: x - 273.15), ("z", Z, lambda x: x / 9.80665)):
    v = nodes(d[name].squeeze(drop=True)).transpose(tn, "latitude", "longitude").values.astype(np.float64)
    for m in range(12):  # среднее по годам и срокам 00+12 UTC (по равному весу)
        acc[m] = cells(conv(v[mon == m].mean(0)))
d.close()
dfiles = sorted(glob.glob(f"{R}/upper_air_cds_daily/[12]*.nc"))
S1 = np.zeros((12, 180, 360)); S2 = np.zeros_like(S1); N = np.zeros(12)
covered = set()
def acc_days(vals, dates):  # vals (дней,181,360) в K, dates datetime64[D]
    mon = dates.astype("datetime64[M]").astype(int) % 12
    for m in range(12):
        if (mon == m).any():
            x = cells(vals[mon == m] - 273.15)
            S1[m] += x.sum(0); S2[m] += (x ** 2).sum(0); N[m] += x.shape[0]
for f in dfiles:
    d = xr.open_dataset(f); tn = tname(d); v = d["t"] if "t" in d else d[list(d.data_vars)[0]]
    v = nodes(v.squeeze(drop=True)).transpose(tn, "latitude", "longitude"); dt = v[tn].values.astype("datetime64[D]")
    acc_days(v.values, dt); covered |= set(dt.tolist()); d.close()
# дни, которых нет в CDS: ARCO-ERA5 1° (HH-18), npz mean [lon 0..359, lat -90..90] float32 K
for f in sorted(glob.glob(R + "/era5_arco/temperature_700/2019-*.npz")):
    day = np.datetime64(os.path.basename(f)[:10])
    if day.tolist() in covered:
        continue
    a = np.load(f)["mean"].T.astype(np.float64)  # (lat, lon0..359)
    acc_days(np.roll(a, 180, axis=-1)[None], np.array([day])); covered.add(day.tolist()); files.append(f)
print("суточных дней", len(covered), "из них ARCO", len(files) - 1)
dfiles = sorted(covered)
if len(dfiles):
    mean = S1 / N[:, None, None]; SD = np.sqrt(np.maximum(S2 / N[:, None, None] - mean ** 2, 0))
else:
    SD = np.full_like(T, np.nan)  # σ не считалась (шлюз Q4)
np.savez(f"{R}/upper_air_climatology.npz", t=T, z=Z, sd=SD, years=np.array(years))
np.savez_compressed(H + "/t700_sd.npz", sd_k=SD.astype(np.float16), years=np.array(years))
print("годы", years[0], years[-1], "месячный файл; суточных", len(dfiles))
print("T", T.min(), T.max(), "Z", Z.min(), Z.max(), "σ", SD.min(), SD.max())
