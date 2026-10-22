"""Суточные u,v 700 гПа (derived-era5-pressure-levels-daily-statistics, daily_mean), 2018–2019 (решение пользователя Q4, 2026-10-22).
Лимит стоимости CDS 400: полгода × одна переменная = 362 -> 8 запросов (2 года × 2 полугодия × u,v). Строго по очереди под ~/data/haze_humidity/cds.lock;
request_id пишется в лог; при остановке (SIGTERM/исключение) запрос удаляется на сервере. Возобновляемо: готовые файлы пропускаются.
Выход: ~/data/haze_humidity/upper_misc_cds/uv700_<г>_h<1|2>_<u|v>.nc.  Запуск: nohup setsid python fetch_wr.py > fetch_wr.log 2>&1 &"""
import os, sys, time, fcntl, signal
import ecmwf.datastores as ds
from common import RAW

OUT = os.path.expanduser(RAW) + "/upper_misc_cds"
KEY = [l.split(": ")[1].strip() for l in open(os.path.expanduser("~/.cdsapirc")) if l.startswith("key")][0]
C = ds.Client(url="https://cds.climate.copernicus.eu/api", key=KEY)
LOCK = open(os.path.expanduser("~/data/haze_humidity/cds.lock"), "w")
CUR = [None]


def cleanup(*a):
    if CUR[0] is not None:
        try: CUR[0].delete(); print("удалён запрос", CUR[0].request_id, flush=True)
        except Exception as e: print("не удалось удалить", repr(e)[-100:], flush=True)
    sys.exit(1)


signal.signal(signal.SIGTERM, cleanup); signal.signal(signal.SIGINT, cleanup)


def get(var, y, h):
    fn = f"{OUT}/uv700_{y}_h{h}_{var[0]}.nc"
    if os.path.exists(fn): return
    months = [f"{m:02d}" for m in range(1, 7)] if h == 1 else [f"{m:02d}" for m in range(7, 13)]
    req = {"product_type": "reanalysis", "variable": [{"u": "u_component_of_wind", "v": "v_component_of_wind"}[var]], "pressure_level": ["700"],
           "year": [str(y)], "month": months, "day": [f"{d:02d}" for d in range(1, 32)], "daily_statistic": "daily_mean",
           "time_zone": "utc+00:00", "frequency": "1_hourly", "grid": [1, 1], "data_format": "netcdf", "download_format": "unarchived"}
    for att in range(30):
        fcntl.flock(LOCK, fcntl.LOCK_EX)
        try:
            t0 = time.time(); r = C.submit("derived-era5-pressure-levels-daily-statistics", req); CUR[0] = r
            print("submit", os.path.basename(fn), r.request_id, flush=True)
            r.download(fn + ".tmp"); os.replace(fn + ".tmp", fn); CUR[0] = None
            print(os.path.basename(fn), "ok", f"{time.time()-t0:.0f} с", os.path.getsize(fn) >> 10, "КБ", flush=True)
            return
        except Exception as e:
            print("ошибка", os.path.basename(fn), att, repr(e)[-200:], flush=True)
            if CUR[0] is not None:
                try: CUR[0].delete()
                except Exception: pass
                CUR[0] = None
        finally:
            fcntl.flock(LOCK, fcntl.LOCK_UN)
        time.sleep(120)


if __name__ == "__main__":
    for y in (2018, 2019):
        for h in (1, 2):
            for v in ("u", "v"): get(v, y, h)
    print("готово", flush=True)
