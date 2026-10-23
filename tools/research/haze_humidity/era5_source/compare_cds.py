"""Сверка суточных статистик ARCO-1° (fetch_arco.py) с CDS derived-era5-*-daily-statistics (уже скачаны, 1°).
Запуск: python compare_cds.py <каталог B> > diff_vs_cds.json"""
import sys, json, glob, os
import numpy as np
import xarray as xr

R = os.path.expanduser("~/data/haze_humidity")
B = sys.argv[1]
lat = np.linspace(90, -90, 181)
w = np.cos(np.radians(lat))[:, None] * np.ones((1, 360))


def load_b(sub, key, days):
    return np.stack([np.load(f"{B}/{sub}/{d}.npz")[key].T[::-1] for d in days])  # [lon,lat↑] -> [lat↓,lon]


def stats(b, c, sel=None):
    d = (b - c).astype(np.float64)
    wd = np.broadcast_to(w, d.shape[1:])
    aw = lambda x: float((x * wd).sum() / (wd.sum() * x.shape[0]))
    ad = np.abs(d)
    return {"n_days": int(d.shape[0]), "bias": round(aw(d), 4), "rmse": round(float(np.sqrt(aw(d ** 2))), 4), "mae": round(aw(ad), 4),
            "p99_abs": round(float(np.percentile(ad, 99)), 3), "p999_abs": round(float(np.percentile(ad, 99.9)), 3), "max_abs": round(float(ad.max()), 3),
            "corr": round(float(np.corrcoef(b.ravel(), c.ravel())[0, 1]), 6)}


def cds(path, var, d0, d1):
    x = xr.open_dataset(path)[var].sel(valid_time=slice(d0, d1))
    if "pressure_level" in x.dims:
        x = x.isel(pressure_level=0)
    return x


out = {}
# 1) T2m суточный максимум, июль 2018
days = [str(d)[:10] for d in np.arange("2018-07-01", "2018-08-01", dtype="datetime64[D]")]
c = cds(f"{R}/surface_t_cds/daily/daily_maximum_utc+0000_2018_m07-12.nc", "t2m", "2018-07-01", "2018-07-31")
assert len(c.valid_time) == 31
out["t2m_daily_max_2018-07"] = stats(load_b("2m_temperature", "max", days), c.values)
# 2) T2m суточный минимум, июнь 2018 (за июль минимум в CDS не скачан)
daysj = [str(d)[:10] for d in np.arange("2018-06-01", "2018-07-01", dtype="datetime64[D]")]
c = cds(f"{R}/surface_t_cds/daily/daily_minimum_utc+0000_2018_m01-06.nc", "t2m", "2018-06-01", "2018-06-30")
out["t2m_daily_min_2018-06"] = stats(load_b("2m_temperature", "min", daysj), c.values)
c = cds(f"{R}/surface_t_cds/daily/daily_maximum_utc+0000_2018_m01-06.nc", "t2m", "2018-06-01", "2018-06-30")
out["t2m_daily_max_2018-06"] = stats(load_b("2m_temperature", "max", daysj), c.values)
# 3) T700 суточное среднее, июль 2018
c = cds(f"{R}/upper_air_cds_daily/2018_h2.nc", "t", "2018-07-01", "2018-07-31")
cv = c.values
out["t700_daily_mean_2018-07"] = stats(load_b("temperature_700", "mean", days), cv)
# 3б) ошибка прореживания по времени относительно полного суточного среднего ARCO (и относительно CDS)
for k in ("mean4", "mean2", "h12"):
    bm = load_b("temperature_700", "mean", days)
    out[f"t700_{k}_vs_full24_arco"] = stats(load_b("temperature_700", k, days), bm)
    out[f"t700_{k}_vs_cds"] = stats(load_b("temperature_700", k, days), cv)
# 4) u700 суточное среднее, июнь 1–10, 2018
d10 = daysj[:10]
c = cds(f"{R}/upper_misc_cds/uv700_2018_h1_u.nc", "u", "2018-06-01", "2018-06-10")
cu = c.values
out["u700_daily_mean_2018-06-01..10"] = stats(load_b("u_component_of_wind_700", "mean", d10), cu)
bm = load_b("u_component_of_wind_700", "mean", d10)
for k in ("mean4", "mean2", "h12"):
    out[f"u700_{k}_vs_full24_arco"] = stats(load_b("u_component_of_wind_700", k, d10), bm)
json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
