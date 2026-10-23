"""Независимая сверка нормам станций (не ERA5): Td — NOAA ISD-Lite (синоптические наблюдения 00 и 12 UTC, 2011–2020),
T700 — NOAA IGRA v2 monthly means (радиозонды 00 и 12 UTC, 2011–2020). Модель — сетки HH1/HH2 в месяце (15-е), Td с поправкой
к высоте станции (HH7). -> stations.json, stations.csv. Запуск: python stations.py  (данные скачаны в RAW, см. README)."""
import csv, datetime as dt, gzip, json, zipfile
import numpy as np
from common import *

# имя: (isd-id, igra-id, lat, lon, z_станции_м)  — координаты и высоты из isd-history.csv / igra2-station-list.txt
ST = {
    "novosibirsk_tolmachevo": ("296340-99999", "RSM00029634", 55.013, 82.651, 111.3),
    "orenburg": ("351210-99999", "RSM00035121", 51.796, 55.457, 118.0),
    "midland_tx": ("722650-23023", "USM00072265", 31.948, -102.209, 872.4),
    "shiraz": ("408480-99999", "IRM00040848", 29.539, 52.589, 1499.6),   # IGRA: данных 2011–2020 нет (только с 2022) — T700 пропускается
    "tehran_mehrabad": ("407540-99999", "IRM00040754", 35.689, 51.313, 1207.6),
}
Y0, Y1 = 2011, 2020
TD, UA = load_td(), load_ua()


def isd_td(sid):
    s = np.zeros((12, 2)); n = np.zeros((12, 2), int)
    for y in range(Y0, Y1 + 1):
        by = {}
        for line in gzip.open(f"{RAW}/isd/{sid}-{y}.gz", "rt"):
            p = line.split()
            h, v = int(p[3]), int(p[5])
            if h in (0, 12) and v != -9999:
                by.setdefault((int(p[1]), int(p[2])), {})[h] = v / 10.0
        for (mo, da), v in by.items():
            if 0 in v and 12 in v:  # день = среднее 00 и 12 UTC, как в сетке
                s[mo - 1, 0] += (v[0] + v[12]) / 2; n[mo - 1, 0] += 1
    return s[:, 0] / np.maximum(n[:, 0], 1), n[:, 0]


def igra_t700(iid):
    vals = {}
    for hh in ("00", "12"):
        with zipfile.ZipFile(f"{RAW}/igra/temp_{hh}z-mly.txt.zip") as z:
            for line in z.open(f"temp_{hh}z-mly.txt"):
                line = line.decode()
                if not line.startswith(iid):
                    continue
                y, m, lev, v = int(line[12:16]), int(line[17:19]), int(line[20:24]), int(line[25:31])
                if lev == 700 and Y0 <= y <= Y1 and v > -9000:
                    vals.setdefault((y, m), {})[hh] = v / 10.0
    mon = np.full(12, np.nan); ny = np.zeros(12, int)
    for m in range(1, 13):
        ys = [(v["00"] + v["12"]) / 2 for (y, mm), v in vals.items() if mm == m and len(v) == 2]
        if ys:
            mon[m - 1] = np.mean(ys); ny[m - 1] = len(ys)
    return mon, ny


out, rows = [], []
for name, (isd, igra, lat, lon, zs) in ST.items():
    td_obs, nd = isd_td(isd)
    zc = float(bil(TD["z"], lat, lon)); tdm = bil(TD["td"], lat, lon); sd = bil(TD["sd"], lat, lon)
    gs = np.array([g_td(lat, dt.date(2015, m + 1, 15)) for m in range(12)])
    td_mod = tdm + gs * (zs - zc) / 1000.0
    t7_obs, ny = igra_t700(igra); t7_mod = bil(UA["t"], lat, lon)
    d_td, d_t7 = td_mod - td_obs, t7_mod - t7_obs
    e = dict(station=name, isd=isd, igra=igra, lat=lat, lon=lon, z_station_m=zs, z_cell_m=round(zc), years=[Y0, Y1],
             td=dict(model_minus_obs_k_by_month=[round(float(x), 2) for x in d_td], bias_k=round(float(d_td.mean()), 2), rms_k=round(float(np.sqrt((d_td ** 2).mean())), 2),
                     max_abs_k=round(float(np.abs(d_td).max()), 2), mean_sigma_k=round(float(sd.mean()), 2), days_per_month_min=int(nd.min())),
             t700=None if not np.isfinite(d_t7).any() else dict(model_minus_obs_k_by_month=[None if not np.isfinite(x) else round(float(x), 2) for x in d_t7],
                       bias_k=round(float(np.nanmean(d_t7)), 2), rms_k=round(float(np.sqrt(np.nanmean(d_t7 ** 2))), 2),
                       max_abs_k=round(float(np.nanmax(np.abs(d_t7))), 2), years_per_month_min=int(ny.min()), months_ok=int(np.isfinite(d_t7).sum())))
    out.append(e)
    for m in range(12):
        rows.append([name, m + 1, round(float(td_obs[m]), 2), round(float(td_mod[m]), 2), round(float(sd[m]), 2), nd[m],
                     "" if not np.isfinite(t7_obs[m]) else round(float(t7_obs[m]), 2), round(float(t7_mod[m]), 2), ny[m]])
    print(name, e["td"]["bias_k"], e["td"]["rms_k"], e["td"]["max_abs_k"], "|", e["t700"] and (e["t700"]["bias_k"], e["t700"]["rms_k"], e["t700"]["max_abs_k"], e["t700"]["months_ok"]))
json.dump(out, open(H + "/stations.json", "w"), ensure_ascii=False, indent=1)
with open(H + "/stations.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["станция", "месяц", "td_набл_C", "td_модель_C", "td_σ_К", "td_дней", "t700_набл_C", "t700_модель_C", "t700_лет"]); w.writerows(rows)
