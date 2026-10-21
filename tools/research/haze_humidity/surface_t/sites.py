"""Сверка: климат TX/DTR ячейки ERA5 против нынешних таблиц configs/weather_model.json (typical_max_c, diurnal.range_k), с
поправкой на высоту долины: v_corr = v_grid + G(сезон) * (z_valley - z_cell)/1000, G — К/км из gradient.json (30–60°N или тропики
по сезонам). Высота долины — как в HH-1 (10-й перцентиль рельефа в радиусе 10 км, AWS Terrain Tiles), кэш valleys_t.json.
sites.csv: место, lat, lon, z_valley_m, месяц, tx_grid_c, tx_corr_c, dtr_grid_k, dtr_corr_k, tx_table_c, dtr_table_k. Запуск: python sites.py"""
import csv, json, os, sys
import numpy as np
from common import RAW

H = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, H + "/../dew_point")
c = np.load(os.path.expanduser(RAW) + "/climatology_t.npz")
cfg = json.load(open(H + "/../../../../configs/weather_model.json"))
TXT, DTRT = cfg["typical_max_c"], cfg["diurnal"]["range_k"]
SITES = {"altai": (51.87, 85.87), "ongudai": (50.79, 86.13), "askarovo": (53.26, 58.54), "aushkul": (54.72, 59.69),
         "crimea": (44.95, 35.12), "darab": (28.75, 54.55), "cairns": (-16.92, 145.77)}
VF = H + "/valleys_t.json"
if os.path.exists(VF):
    v = json.load(open(VF))
else:
    from valleys import valley  # HH-1: 10-й перцентиль рельефа в радиусе 10 км, AWS Terrain Tiles
    v = {k: {"lat": la, "lon": lo, "valley_p10_m": round(valley(la, lo)[0], 1)} for k, (la, lo) in SITES.items()}
    json.dump(v, open(VF, "w"), indent=1)
G = json.load(open(H + "/gradient.json"))
SEAS = {0: "DJF", 1: "DJF", 11: "DJF", 2: "MAM", 3: "MAM", 4: "MAM", 5: "JJA", 6: "JJA", 7: "JJA", 8: "SON", 9: "SON", 10: "SON"}


def grad(var, lat, m):
    reg = "land_tropics_20S_20N" if abs(lat) <= 20 else "land_30_60N"
    return G[var][reg][SEAS[m]]["pooled_k_per_km"]


def bil(a, lat, lon):
    fj = lat + 89.5; fi = lon + 179.5
    j0 = int(np.floor(fj)); i0 = int(np.floor(fi)); tj = fj - j0; ti = fi - i0
    j0 = min(max(j0, 0), 178); i0 = i0 % 360; i1 = (i0 + 1) % 360
    return (a[..., j0, i0] * (1 - tj) * (1 - ti) + a[..., j0, i1] * (1 - tj) * ti + a[..., j0 + 1, i0] * tj * (1 - ti) + a[..., j0 + 1, i1] * tj * ti)


rows = []
for k, (la, lo) in SITES.items():
    zv = max(0.0, v[k]["valley_p10_m"]); zc = float(bil(c["z"], la, lo))
    tx = bil(c["tx"], la, lo); dtr = bil(c["dtr"], la, lo)
    for m in range(12):
        dz = (zv - zc) / 1000
        rows.append([k, la, lo, zv, round(zc, 1), m + 1, round(float(tx[m]), 2), round(float(tx[m] + grad("tx", la, m) * dz), 2),
                     round(float(dtr[m]), 2), round(float(max(0, dtr[m] + grad("dtr", la, m) * dz)), 2), TXT[m], DTRT[m]])
with open(H + "/sites.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["место", "lat", "lon", "z_valley_m", "z_cell_m", "месяц", "tx_grid_c", "tx_corr_c", "dtr_grid_k", "dtr_corr_k", "tx_table_c", "dtr_table_k"])
    w.writerows(rows)
for k in SITES:
    r = [x for x in rows if x[0] == k]
    print(k, "z_cell", r[0][4], "z_valley", r[0][3]); print("  tx_corr", [x[7] for x in r]); print("  dtr_corr", [x[9] for x in r])
