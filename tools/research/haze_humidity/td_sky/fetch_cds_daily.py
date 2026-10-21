"""CDS derived-era5-single-levels-daily-statistics (UTC-сутки, 1_hourly, сетка 1x1): total_cloud_cover daily_mean и 2m_temperature daily_maximum.
Правила CDS (решение 2026-10-22): один процесс, запросы по очереди, каждый под общим замком ~/data/haze_humidity/cds.lock.
Файл на (статистика, год) -> ~/data/haze_humidity/td_sky/cds/<stat>_<год>.nc; готовые пропускаются.
Порядок: 2013 (сверка с ARCO), затем 2014-2020. Запрос на год×переменную (очередь CDS медленная). Запуск: python fetch_cds_daily.py"""
import os, sys, time, calendar, fcntl
from ecmwf.datastores import Client

OUT = os.path.expanduser("~/data/haze_humidity/td_sky/cds"); os.makedirs(OUT, exist_ok=True)
LOCK = os.path.expanduser("~/data/haze_humidity/cds.lock")
STATS = {"tcc": ("total_cloud_cover", "daily_mean"), "tmax": ("2m_temperature", "daily_maximum")}


def log(*a): print(time.strftime("%H:%M:%S"), *a, flush=True)


def one(key, y):
    fn = f"{OUT}/{key}_{y}.nc"
    if os.path.exists(fn): return
    var, st = STATS[key]
    req = {"product_type": "reanalysis", "variable": [var], "year": str(y), "month": [f"{m:02d}" for m in range(1, 13)],
           "day": [f"{d:02d}" for d in range(1, 32)], "daily_statistic": st, "time_zone": "utc+00:00", "frequency": "1_hourly",
           "grid": [1.0, 1.0], "data_format": "netcdf", "download_format": "unarchived"}
    for att in range(50):
        r = None
        try:
            with open(LOCK, "w") as lk:
                log("жду замок", key, y); fcntl.flock(lk, fcntl.LOCK_EX)
                r = CL.submit("derived-era5-single-levels-daily-statistics", req)
                log("submit", key, y, "request_id", r.request_id)
                t0 = time.time()
                while True:
                    r.update(); stt = r.status
                    if stt == "successful": break
                    if stt in ("failed", "rejected", "deleted"): raise RuntimeError(f"статус {stt}")
                    if int(time.time() - t0) % 300 < 20: log("статус", stt, r.request_id)
                    time.sleep(20)
                r.download(fn + ".part"); os.replace(fn + ".part", fn); log("ok", key, y, os.path.getsize(fn) >> 20, "МБ"); return
        except BaseException as e:
            log("err", key, y, att, repr(e)[:300])
            if r is not None:
                try: r.delete(); log("запрос удалён на сервере", r.request_id)
                except Exception as e2: log("delete не удалось", repr(e2)[:100])
            if isinstance(e, (KeyboardInterrupt, SystemExit)): raise
            time.sleep(60)


def _term(*a): raise SystemExit(1)  # SIGTERM -> except BaseException удаляет запрос


if __name__ == "__main__":
    import signal; signal.signal(signal.SIGTERM, _term)
    cfg = dict(l.split(": ", 1) for l in open(os.path.expanduser("~/.cdsapirc")).read().strip().splitlines())
    CL = Client(url=cfg["url"].strip(), key=cfg["key"].strip())
    for y in [2013] + list(range(2014, 2021)):
        for key in STATS: one(key, y)
    log("done")
