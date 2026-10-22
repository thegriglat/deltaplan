"""CDS derived-era5-single-levels-daily-statistics: 2m_temperature daily_maximum / daily_minimum, 1_hourly, сетка 1x1, UTC-сутки.
Правила координатора 2026-10-22: один процесс, запросы по одному под общим замком ~/data/haze_humidity/cds_single.lock; лимит стоимости CDS (403
'too large') -> дробление (по месяцам); request_id в лог; при остановке/ошибке запрос на сервере удаляется (get_remote(id).delete()).
Выход RAW/surface_t_cds/daily/<stat>_<tz>_<год>_m<мм-мм>.nc. Возобновляемо. Запуск (nohup setsid): python cds_daily.py <time_zone> <годы...>
Размер куска (число месяцев в запросе) — env CHUNK (по умолчанию 12; при отказе по стоимости делится пополам)."""
import fcntl, os, sys, time
import cdsapi
from ecmwf.datastores import Client
from common import RAW

OUT = os.path.expanduser(RAW) + "/surface_t_cds/daily"
os.makedirs(OUT, exist_ok=True)
STATS = ("daily_maximum", "daily_minimum")
url, key = cdsapi.api.get_url_key_verify(None, None, None)[:2]
cli = Client(url=url, key=key)
chunk = int(os.environ.get("CHUNK", "12"))


def fetch(stat, tz, y, months):
    fn = f"{OUT}/{stat}_{tz.replace(':', '')}_{y}_m{months[0]:02d}-{months[-1]:02d}.nc"
    if os.path.exists(fn):
        return True
    req = {"product_type": "reanalysis", "variable": ["2m_temperature"], "year": str(y), "month": [f"{m:02d}" for m in months],
           "day": [f"{d:02d}" for d in range(1, 32)], "daily_statistic": stat, "time_zone": tz, "frequency": "1_hourly", "grid": [1.0, 1.0],
           "data_format": "netcdf", "download_format": "unarchived"}
    fails = 0
    while fails < 3:
        rem = None
        try:
            with open(os.path.expanduser(RAW) + "/cds_single.lock", "w") as lk:
                fcntl.flock(lk, fcntl.LOCK_EX)
                print(stat, tz, y, months, "замок взят", flush=True)
                rem = cli.submit("derived-era5-single-levels-daily-statistics", req)
                print("request_id", rem.request_id, flush=True)
                rem.download(fn + ".part")
            os.replace(fn + ".part", fn)
            print(stat, tz, y, months, "ok", os.path.getsize(fn), flush=True)
            return True
        except BaseException as e:
            msg = str(e)
            print(stat, tz, y, months, "ошибка", type(e).__name__, msg[:300], flush=True)
            if rem is not None:
                try:
                    rem.delete(); print("запрос удалён", flush=True)
                except Exception as e2:
                    print("удалить не удалось", e2, flush=True)
            if not isinstance(e, Exception):
                raise
            if "too large" in msg or "cost limit" in msg or "403" in msg:
                return False
            fails += 1; time.sleep(300)
    raise SystemExit("blocked: CDS отказывает")


def fetch_split(stat, tz, y, months):
    if fetch(stat, tz, y, months):
        return
    assert len(months) > 1, "один месяц не проходит по стоимости"
    h = len(months) // 2
    fetch_split(stat, tz, y, months[:h]); fetch_split(stat, tz, y, months[h:])


if __name__ == "__main__":
    tz = sys.argv[1]
    for y in [int(v) for v in sys.argv[2:]]:
        for s in STATS:
            for i in range(0, 12, chunk):
                fetch_split(s, tz, y, list(range(1 + i, 1 + min(12, i + chunk))))
    print("готово", flush=True)
