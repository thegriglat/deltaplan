"""CDS (агрегированные наборы ERA5, решение 2026-10-22): 2011–2020, сетка 1°, 700 гПа. Запросы (очередь CDS длинная),
последовательно, каждый под общим замком ~/data/haze_humidity/cds.lock (submit -> ожидание -> скачивание):
 1) reanalysis-era5-pressure-levels-monthly-means, monthly_averaged_reanalysis_by_hour_of_day, temperature+geopotential,
    time 00:00 и 12:00, 10 лет x 12 месяцев -> RAW/upper_air_cds/2011_2020.nc
 2) derived-era5-pressure-levels-daily-statistics, temperature, daily_mean, 1_hourly, utc+00:00, год x полугодие (лимит стоимости 400)
    -> RAW/upper_air_cds_daily/<год>_h1|h2.nc  (аргумент: monthly | daily | all)
request_id пишется в лог; при остановке (SIGTERM/исключение) запрос на сервере удаляется.
Запуск: nohup setsid python fetch_cds.py > log 2>&1 &   (готовые файлы пропускаются)"""
import fcntl, os, signal, sys, time
from ecmwf.datastores import Client
from common import RAW

R = os.path.expanduser(RAW)
M = R + "/upper_air_cds"; D = R + "/upper_air_cds_daily"
os.makedirs(M, exist_ok=True); os.makedirs(D, exist_ok=True)
key = dict(l.split(": ", 1) for l in open(os.path.expanduser("~/.cdsapirc")).read().strip().splitlines() if ": " in l)
cl = Client(url=key["url"], key=key["key"])
lock = open(R + "/cds.lock", "w")
YEARS = [str(y) for y in range(2011, 2021)]
months = [f"{m:02d}" for m in range(1, 13)]
cur = {"r": None}


def cleanup(*a):
    r = cur["r"]
    if r is not None:
        try:
            r.delete(); print("удалён запрос", r.request_id, flush=True)
        except Exception as e:
            print("не удалён", e, flush=True)
    sys.exit(1)


signal.signal(signal.SIGTERM, cleanup); signal.signal(signal.SIGINT, cleanup)


def run(fn, ds, req):
    if os.path.exists(fn):
        return True
    t0 = time.time()
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        print(fn, "замок взят", f"{time.time()-t0:.0f} с", flush=True)
        r = cl.submit(ds, req); cur["r"] = r
        print(fn, "request_id", r.request_id, flush=True)
        r.download(fn + ".tmp"); os.replace(fn + ".tmp", fn); cur["r"] = None
        print(fn, "ok", f"{time.time()-t0:.0f} с", os.path.getsize(fn), "байт", flush=True)
        return True
    except SystemExit:
        raise
    except Exception as e:
        print(fn, "ошибка", str(e)[-300:].replace("\n", " "), flush=True)
        if cur["r"] is not None:
            try: cur["r"].delete()
            except Exception: pass
            cur["r"] = None
        return False
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)


def retry(fn, ds, req, n=100):
    for att in range(n):
        if run(fn, ds, req):
            return True
        time.sleep(60)
    return False


import sys
which = sys.argv[1] if len(sys.argv) > 1 else "all"
if which in ("monthly", "all"):
    retry(f"{M}/2011_2020.nc", "reanalysis-era5-pressure-levels-monthly-means", {
        "product_type": "monthly_averaged_reanalysis_by_hour_of_day", "variable": ["temperature", "geopotential"],
        "pressure_level": "700", "year": YEARS, "month": months, "time": ["00:00", "12:00"],
        "grid": [1.0, 1.0], "data_format": "netcdf"})
base = {"product_type": "reanalysis", "variable": ["temperature"], "pressure_level": "700",
        "day": [f"{d:02d}" for d in range(1, 32)], "daily_statistic": "daily_mean", "time_zone": "utc+00:00",
        "frequency": "1_hourly", "grid": [1.0, 1.0], "data_format": "netcdf"}
if which in ("daily", "all"):
    # лимит стоимости CDS 400 (год x 6 месяцев = 366 проходит; год целиком = 730 нет) -> 20 запросов: год x полугодие
    for y in YEARS:
        for h, ms in ((1, months[:6]), (2, months[6:])):
            retry(f"{D}/{y}_h{h}.nc", "derived-era5-pressure-levels-daily-statistics", dict(base, year=y, month=ms))
print("все загрузки завершены", flush=True)
