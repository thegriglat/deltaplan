"""σ суточной T700: ERA5 pressure-levels (CDS), temperature 700 гПа, 00 и 12 UTC каждого дня, запрос = год (730 полей).
Результат RAW/upper_air_cds_daily/<год>.nc (0.25°). Запросы последовательно, при отказе очереди — повтор.
Запуск: python fetch_cds_daily.py 1991 2020"""
import os, sys, time
import cdsapi
from common import RAW

OUT = os.path.expanduser(RAW) + "/upper_air_cds_daily"
os.makedirs(OUT, exist_ok=True)
y0, y1 = int(sys.argv[1]), int(sys.argv[2])
c = cdsapi.Client(quiet=True)
for y in range(y0, y1 + 1):
    fn = f"{OUT}/{y}.nc"
    if os.path.exists(fn):
        continue
    t0 = time.time()
    for att in range(500):
        try:
            c.retrieve("reanalysis-era5-pressure-levels", {
                "product_type": "reanalysis", "variable": ["temperature"], "pressure_level": "700", "year": str(y),
                "month": [f"{m:02d}" for m in range(1, 13)], "day": [f"{d:02d}" for d in range(1, 32)],
                "time": ["00:00", "12:00"], "data_format": "netcdf"}, fn + ".tmp")
            break
        except Exception as e:
            print(y, "повтор", att, str(e)[-100:].replace("\n", " "), flush=True)
            time.sleep(120)
    os.replace(fn + ".tmp", fn)
    print(y, "ok", f"{time.time()-t0:.0f} с", flush=True)
