"""Загрузка агрегированных наборов ERA5 с CDS (CC-BY), 1°×1°, 2011–2020, всё вне репозитория RAW/upper_misc_cds/.
Правила (решение пользователя 2026-10-22): один процесс, запросы строго по очереди под общим замком ~/data/haze_humidity/cds.lock.
 sl_monthly.nc  single-levels-monthly-means: high_cloud_cover, 10m_wind_speed (monthly_averaged_reanalysis, все годы, один запрос)
 tz.nc          pressure-levels-monthly-means: temperature, geopotential, 500…50 гПа (один запрос)
 u700_<г>.nc  derived-era5-pressure-levels-daily-statistics: u,v 700 гПа daily_mean (по году)
Запуск: python fetch_cds.py   (возобновляемо: готовые файлы пропускаются)"""
import os, sys, time, fcntl
import cdsapi
from common import RAW

OUT = os.path.expanduser(RAW) + "/upper_misc_cds"
os.makedirs(OUT, exist_ok=True)
YEARS = [str(y) for y in range(2011, 2021)]
MONTHS = [f"{m:02d}" for m in range(1, 13)]
LEVELS = ["500", "450", "400", "350", "300", "250", "225", "200", "175", "150", "125", "100", "70", "50"]
FMT = {"grid": [1, 1], "data_format": "netcdf", "download_format": "unarchived"}
LOCK = open(os.path.expanduser("~/data/haze_humidity/cds.lock"), "w")


def get(ds, body, fn):
    if os.path.exists(fn):
        return True
    c = cdsapi.Client(quiet=True)
    for att in range(50):
        fcntl.flock(LOCK, fcntl.LOCK_EX)
        try:
            t0 = time.time()
            c.retrieve(ds, dict(body, **FMT), fn + ".tmp")
            os.replace(fn + ".tmp", fn)
            print(os.path.basename(fn), "ok", f"{time.time()-t0:.0f} с", os.path.getsize(fn) >> 10, "КБ", flush=True)
            return True
        except Exception as e:
            print("ошибка", os.path.basename(fn), att, repr(e)[-200:], flush=True)
        finally:
            fcntl.flock(LOCK, fcntl.LOCK_UN)
        time.sleep(60)
    return False


if __name__ == "__main__":
    get("reanalysis-era5-single-levels-monthly-means", {"product_type": ["monthly_averaged_reanalysis"], "variable": ["high_cloud_cover", "10m_wind_speed"],
        "year": YEARS, "month": MONTHS, "time": ["00:00"]}, OUT + "/sl_monthly.nc")
    get("reanalysis-era5-pressure-levels-monthly-means", {"product_type": ["monthly_averaged_reanalysis"], "variable": ["temperature", "geopotential"],
        "pressure_level": LEVELS, "year": YEARS, "month": MONTHS, "time": ["00:00"]}, OUT + "/tz.nc")
    for y in YEARS:  # не мельче года (решение 2026-10-22)
        get("derived-era5-pressure-levels-daily-statistics", {"product_type": "reanalysis", "variable": ["u_component_of_wind", "v_component_of_wind"],
            "pressure_level": ["700"], "year": y, "month": MONTHS, "day": [f"{d:02d}" for d in range(1, 32)], "daily_statistic": "daily_mean",
            "time_zone": "utc+00:00", "frequency": "1_hourly"}, f"{OUT}/u700_{y}.nc")
    # оценка занижения модуля суточного среднего вектора против среднего модуля: 10 м u,v daily_mean за один год (сверка с 10m_wind_speed)
    get("derived-era5-single-levels-daily-statistics", {"product_type": "reanalysis", "variable": ["10m_u_component_of_wind", "10m_v_component_of_wind"],
        "year": "2015", "month": MONTHS, "day": [f"{d:02d}" for d in range(1, 32)], "daily_statistic": "daily_mean",
        "time_zone": "utc+00:00", "frequency": "1_hourly"}, OUT + "/u10_2015.nc")
    print("готово", flush=True)
