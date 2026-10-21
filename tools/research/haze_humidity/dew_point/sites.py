"""Сверка: климат Td ячейки ERA5 против нынешней таблицы dew_point_c, с поправкой на высоту долины.
td_corr = td_grid + G(сезон) * (z_valley - z_cell)/1000, G — К/км из gradient.json (регион land_30_60N по сезонам,
для тропиков/субтропиков — land_tropics). sites.csv: место, lat, lon, z_valley_m, z_cell_m, месяц, td_grid_c, td_corr_c,
sd_k, td_table_c. Запуск: python sites.py [G_К_на_км — единое значение вместо сезонного]"""
import csv, json, os, sys
import numpy as np
from common import RAW

H = os.path.dirname(os.path.abspath(__file__))
c = np.load(os.path.expanduser(RAW) + "/climatology.npz")
v = json.load(open(H + "/valleys.json"))
TABLE = [-19, -18, -11, -3, 2, 7, 9, 8, 3, -2, -9, -16]
G = json.load(open(H + "/gradient.json"))
SEAS = {0: "DJF", 1: "DJF", 11: "DJF", 2: "MAM", 3: "MAM", 4: "MAM", 5: "JJA", 6: "JJA", 7: "JJA", 8: "SON", 9: "SON", 10: "SON"}
fixed = float(sys.argv[1]) if len(sys.argv) > 1 else None


def grad(lat, m):
    if fixed is not None:
        return fixed
    reg = "land_tropics_20S_20N" if abs(lat) <= 20 else "land_30_60N"
    e = G[reg][SEAS[m]]
    return e["pooled_k_per_km"]


def bil(a, lat, lon):  # билинейно по центрам ячеек 1°
    fj = lat + 89.5; fi = lon + 179.5
    j0 = int(np.floor(fj)); i0 = int(np.floor(fi)); tj = fj - j0; ti = fi - i0
    j0 = min(max(j0, 0), 178); i0 = i0 % 360; i1 = (i0 + 1) % 360
    return (a[..., j0, i0] * (1 - tj) * (1 - ti) + a[..., j0, i1] * (1 - tj) * ti + a[..., j0 + 1, i0] * tj * (1 - ti) + a[..., j0 + 1, i1] * tj * ti)


rows = []
for k, s in v.items():
    zv = max(0.0, s["valley_p10_m"])  # море/бухта в DEM: уровень моря
    td = bil(c["td"], s["lat"], s["lon"]); sd = bil(c["sd"], s["lat"], s["lon"]); zc = float(bil(c["z"], s["lat"], s["lon"]))
    for m in range(12):
        corr = td[m] + grad(s["lat"], m) * (zv - zc) / 1000
        rows.append([k, s["lat"], s["lon"], zv, round(zc, 1), m + 1, round(float(td[m]), 2), round(float(corr), 2), round(float(sd[m]), 2), TABLE[m]])
with open(H + "/sites.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["место", "lat", "lon", "z_valley_m", "z_cell_m", "месяц", "td_grid_c", "td_corr_c", "sd_k", "td_table_c"])
    w.writerows(rows)
for k in v:
    r = [x for x in rows if x[0] == k]
    print(k, "z_cell", r[0][4], "z_valley", r[0][3], "corr", [x[7] for x in r])
