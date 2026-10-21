"""Скачивание ERA5 с CDS (ключ ~/.cdsapirc, CC-BY): сетка 1°×1° (интерполяция CDS), всё вне репозитория RAW/upper_misc_cds/.
 daily  <год>: u,v 700 гПа (pressure-levels) и 10m u,v + high_cloud_cover (single-levels), 00 и 12 UTC, все сутки -> daily_<год>.nc (3 файла: pl, sl)
 tz: monthly_averaged_reanalysis, T и Z, уровни 500…50 гПа -> tz_2011.nc (один запрос на все годы 2011–2020)
Запуск: python fetch_cds.py daily 2011 2020 | python fetch_cds.py tz 2011 2011 1 (очередь CDS: не более одного запроса на набор данных). Возобновляемо."""
import os, sys, time
from concurrent.futures import ThreadPoolExecutor
import cdsapi
from common import RAW

OUT = os.path.expanduser(RAW) + "/upper_misc_cds"
os.makedirs(OUT, exist_ok=True)
LEVELS = ["500", "450", "400", "350", "300", "250", "225", "200", "175", "150", "125", "100", "70", "50"]
MONTHS = [f"{m:02d}" for m in range(1, 13)]
BASE = {"year": None, "month": MONTHS, "grid": [1, 1], "data_format": "netcdf", "download_format": "unarchived"}


def job(a):
    kind, y = a
    only = os.environ.get("ONLY")  # pl | sl | tz — запускать по набору данных отдельным процессом (очередь CDS — по набору данных)
    c = cdsapi.Client(quiet=True)
    if kind == "daily":
        req = [("pl", "reanalysis-era5-pressure-levels", {"variable": ["u_component_of_wind", "v_component_of_wind"], "pressure_level": ["700"]}),
               ("sl", "reanalysis-era5-single-levels", {"variable": ["10m_u_component_of_wind", "10m_v_component_of_wind", "high_cloud_cover"]})]
        extra = {"day": [f"{d:02d}" for d in range(1, 32)], "time": ["00:00", "12:00"], "product_type": ["reanalysis"]}
    else:
        req = [("tz", "reanalysis-era5-pressure-levels-monthly-means", {"variable": ["temperature", "geopotential"], "pressure_level": LEVELS})]
        extra = {"product_type": ["monthly_averaged_reanalysis"], "time": ["00:00"]}
    for tag, ds, r in req:
        if only and tag != only:
            continue
        fn = f"{OUT}/{tag}_{y}.nc"
        if os.path.exists(fn):
            continue
        t0 = time.time()
        body = dict(BASE, year=([str(v) for v in range(2011, 2021)] if kind == "tz" else str(y)), **extra, **r)
        for att in range(400):
            try:
                c.retrieve(ds, body, fn + ".tmp"); break
            except Exception as e:
                print("повтор", tag, y, att, repr(e)[:150], flush=True); time.sleep(60 + (hash((tag, y)) % 40))
        else:
            raise RuntimeError(f"{tag} {y}")
        os.replace(fn + ".tmp", fn)
        print(tag, y, "ok", f"{time.time()-t0:.0f} с", os.path.getsize(fn) >> 20, "МБ", flush=True)


if __name__ == "__main__":
    kind, y0, y1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 4
    with ThreadPoolExecutor(n) as ex:
        list(ex.map(job, [(kind, y) for y in range(y0, y1 + 1)]))
    print("готово", flush=True)
