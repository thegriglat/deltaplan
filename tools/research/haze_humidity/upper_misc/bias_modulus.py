"""Оценка занижения |V700| по суточному среднему вектору: отношение <|V|>_часы / |<V>|_сутки на 700 гПа, ARCO-ERA5 1° почасовой (era5_source/fetch_arco.py, то же хранилище).
Выборка: сутки 10–12 января и июля 2018 (6 суток; 2 потока). Выход: RAW/upper_misc_bias.npz (ratio[2,180,360] — по сезонам янв/июл), печать по поясам и местам.
Запуск: python bias_modulus.py"""
import os, sys, datetime as dt, numpy as np, zarr, gcsfs
from concurrent.futures import ThreadPoolExecutor
from common import RAW
from aggregate_cds import cells
STORE = "gcp-public-data-arco-era5/ar/1959-2022-1h-360x181_equiangular_with_poles_conservative.zarr"
fs = gcsfs.GCSFileSystem(token="anon", requests_timeout=120); g = zarr.open_consolidated(fs.get_mapper(STORE), mode="r")
li = list(g["level"][:]).index(700); T0 = dt.datetime(1959, 1, 1)
def day(d):
    i0 = int((dt.datetime(d.year, d.month, d.day) - T0).total_seconds() // 3600)
    out = []
    for v in ("u_component_of_wind", "v_component_of_wind"):
        out.append(np.concatenate([np.asarray(g[v][i0 + 8 * j:i0 + 8 * j + 8, li], np.float64) for j in range(3)], 0))
    u, v = out
    return np.hypot(u, v).mean(0), np.hypot(u.mean(0), v.mean(0))  # [lon,lat]
res = {}
with ThreadPoolExecutor(2) as ex:
    for mon in (1, 7):
        ds = [dt.date(2018, mon, k) for k in (10, 11, 12)]
        r = list(ex.map(day, ds)); res[mon] = (np.mean([a for a, b in r], 0), np.mean([b for a, b in r], 0))
        print("готов месяц", mon, flush=True)
ratio = np.stack([cells((res[m][0] / np.maximum(res[m][1], 0.1)).T[::-1]) for m in (1, 7)])
num = np.stack([cells(res[m][0].T[::-1]) for m in (1, 7)]); den = np.stack([cells(res[m][1].T[::-1]) for m in (1, 7)])
np.savez(os.path.expanduser(RAW) + "/upper_misc_bias.npz", ratio=ratio, mean_speed=num, speed_of_mean=den)
w = np.cos(np.radians(-89.5 + np.arange(180)))
for k, m in enumerate((1, 7)):
    for lo, hi in ((0, 20), (20, 40), (40, 60), (60, 75)):
        for nm, sl in (("с", slice(90 + lo, 90 + hi)), ("ю", slice(90 - hi, 90 - lo))):
            a = num[k][sl].sum() / den[k][sl].sum(); print(f"мес {m} {nm} {lo}-{hi}: <|V|>/|<V>| (отношение сумм) {a:.3f}")
