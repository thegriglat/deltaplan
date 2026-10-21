"""Месячные средние ERA5 по часам суток, 700 гПа, T и Z (CDS): датасет reanalysis-era5-pressure-levels-monthly-means,
product_type monthly_averaged_reanalysis_by_hour_of_day, time 00:00 и 12:00, temperature и geopotential. Запрос = год.
Результат RAW/upper_air_cds/<год>.nc (0.25°; 1° — в aggregate_cds.py). Ключ: ~/.cdsapirc.
Очередь CDS на набор ограничена («Maximum number queued requests»): запросы последовательно, при отказе ждём и повторяем.
Запуск: python fetch_cds.py 1991 2020"""
import os, sys, time
import cdsapi
from common import RAW

OUT = os.path.expanduser(RAW) + "/upper_air_cds"
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
            c.retrieve("reanalysis-era5-pressure-levels-monthly-means", {
                "product_type": "monthly_averaged_reanalysis_by_hour_of_day", "variable": ["temperature", "geopotential"],
                "pressure_level": "700", "year": str(y), "month": [f"{m:02d}" for m in range(1, 13)],
                "time": ["00:00", "12:00"], "data_format": "netcdf"}, fn + ".tmp")
            break
        except Exception as e:
            print(y, "повтор", att, str(e)[-100:].replace("\n", " "), flush=True)
            time.sleep(120)
    os.replace(fn + ".tmp", fn)
    print(y, "ok", f"{time.time()-t0:.0f} с", flush=True)
