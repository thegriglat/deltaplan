"""Сверка T700/Z700 сетки с нынешней таблицей upper_air (configs/weather_model.json) для мест игры.
sites.csv: место, lat, lon, месяц, t700_grid_c, z700_grid_m, t700_sd_k, t_table_c, z_table_m. Запуск: python sites.py"""
import csv, json, os
import numpy as np
from common import RAW

H = os.path.dirname(os.path.abspath(__file__))
c = np.load(os.path.expanduser(RAW) + "/upper_air_climatology.npz")
cfg = json.load(open(H + "/../../../../configs/weather_model.json"))["upper_air"]
SITES = {"altai": (51.87, 85.87), "ongudai": (50.79, 86.13), "askarovo": (53.26, 58.54), "aushkul": (54.72, 59.69),
         "crimea": (44.95, 35.12), "dry_darab": (28.75, 54.55), "wet_cairns": (-16.92, 145.77)}


def bil(a, lat, lon):
    fj = lat + 89.5; fi = lon + 179.5
    j0 = int(np.floor(fj)); i0 = int(np.floor(fi)); tj = fj - j0; ti = fi - i0
    j0 = min(max(j0, 0), 178); i0 %= 360; i1 = (i0 + 1) % 360
    return a[..., j0, i0] * (1 - tj) * (1 - ti) + a[..., j0, i1] * (1 - tj) * ti + a[..., j0 + 1, i0] * tj * (1 - ti) + a[..., j0 + 1, i1] * tj * ti


rows = []
for k, (lat, lon) in SITES.items():
    t, z, sd = bil(c["t"], lat, lon), bil(c["z"], lat, lon), bil(c["sd"], lat, lon)
    for m in range(12):
        rows.append([k, lat, lon, m + 1, round(float(t[m]), 2), round(float(z[m]), 1), round(float(sd[m]), 2), cfg["temp_c"][m], cfg["z_msl_m"]])
with open(H + "/sites.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["место", "lat", "lon", "месяц", "t700_grid_c", "z700_grid_m", "t700_sd_k", "t_table_c", "z_table_m"]); w.writerows(rows)
GAM = 9.8 - cfg["lapse_k_per_km"]
for k in SITES:
    r = [x for x in rows if x[0] == k]
    print(k, "T-T_table", [round(x[4] - x[7], 1) for x in r], "Z", [x[5] for x in r])
    if k in ("altai", "ongudai", "askarovo", "aushkul"):
        print("   Δz_dry м", [round((x[4] - x[7]) / GAM * 1000) for x in r])
