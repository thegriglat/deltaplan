"""Конвейер под CDS (НЕ ЗАПУСКАЛСЯ — ключа CDS нет). Месячные средние ERA5 по часам суток, 700 гПа, T и Z:
датасет reanalysis-era5-pressure-levels-monthly-means, product_type monthly_averaged_reanalysis_by_hour_of_day,
time 00:00 и 12:00, variable temperature и geopotential, 1991–2020. Результат — RAW/upper_air_cds/<год>.nc (0.25° → 1° в aggregate_cds.py).
Ключ: ~/.cdsapirc (https://cds.climate.copernicus.eu/how-to-api). Запуск: python fetch_cds.py 1991 2020
Ограничение: месячные средние не дают σ суточной T700 (t700_sd.npz) — её по-прежнему даёт fetch.py + aggregate.py (суточные сроки ARCO),
либо запрос reanalysis-era5-pressure-levels по дням (очередь CDS, долго)."""
import os, sys
import cdsapi
from common import RAW

OUT = os.path.expanduser(RAW) + "/upper_air_cds"
os.makedirs(OUT, exist_ok=True)
y0, y1 = int(sys.argv[1]), int(sys.argv[2])
c = cdsapi.Client()
for y in range(y0, y1 + 1):
    fn = f"{OUT}/{y}.nc"
    if os.path.exists(fn):
        continue
    c.retrieve("reanalysis-era5-pressure-levels-monthly-means", {
        "product_type": "monthly_averaged_reanalysis_by_hour_of_day", "variable": ["temperature", "geopotential"],
        "pressure_level": "700", "year": str(y), "month": [f"{m:02d}" for m in range(1, 13)], "time": ["00:00", "12:00"],
        "data_format": "netcdf"}, fn + ".tmp")
    os.replace(fn + ".tmp", fn)
    print(y, "ok", flush=True)
