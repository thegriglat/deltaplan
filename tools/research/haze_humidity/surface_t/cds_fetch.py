"""CDS: ERA5 monthly-means by_hour_of_day, 2m_temperature, 0.25°, по одному году на запрос (12 мес x 24 срока UTC).
Выход RAW/surface_t_cds/t2m_<год>.nc. Возобновляемо (готовые пропускаются). Параллельно N запросов.
Запуск (через nohup setsid, не dpcli job): python cds_fetch.py <потоков> 1991 1992 ..."""
import os, sys, time
from concurrent.futures import ThreadPoolExecutor
import cdsapi
from common import RAW

OUT = os.path.expanduser(RAW) + "/surface_t_cds"
os.makedirs(OUT, exist_ok=True)


def one(y):
    fn = f"{OUT}/t2m_{y}.nc"
    if os.path.exists(fn):
        return
    for att in range(6):
        try:
            c = cdsapi.Client(quiet=True)
            c.retrieve("reanalysis-era5-single-levels-monthly-means", {
                "product_type": "monthly_averaged_reanalysis_by_hour_of_day", "variable": "2m_temperature",
                "year": str(y), "month": [f"{m:02d}" for m in range(1, 13)], "time": [f"{h:02d}:00" for h in range(24)],
                "data_format": "netcdf", "download_format": "unarchived"}, fn + ".part")
            os.replace(fn + ".part", fn)
            print(y, "ok", os.path.getsize(fn), flush=True)
            return
        except Exception as e:
            print(y, "ошибка", att, type(e).__name__, str(e)[:200], flush=True); time.sleep(60)


if __name__ == "__main__":
    n = int(sys.argv[1]); ys = [int(v) for v in sys.argv[2:]]
    with ThreadPoolExecutor(n) as ex:
        list(ex.map(one, ys))
    print("готово", flush=True)
