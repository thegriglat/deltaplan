"""Этап B: TX/TN/DTR = максимум/минимум среднего хода 2011-2020 + поправка недобора (CDS daily-statistics 2018-2019) -> RAW/climatology_t.npz.
Вход: RAW/surface_t_cds/course_stats.npz (course.py), RAW/surface_t_cds/daily/{daily_maximum,daily_minimum}_utc+0000_<год>_m*.nc (1°, cds_daily.py),
RAW/climatology.npz (z, lsm, z025, lsm025 из HH-1).
Поправка (Dx >= 0 для максимума, Dn <= 0 для минимума) считается в узлах сетки 1° (там живёт daily-statistics): по годам 2018 и 2019
  Dx_y(m) = среднее по дням месяца суточного максимума (UTC-сутки) - max по 24 часам среднего хода года y в том же узле; Dn_y аналогично.
Dx = среднее Dx_y по двум годам. Неравенство среднее(max) >= max(среднее) выполняется при одинаковом окне суток => Dx >= 0 точно.
Перенос: TX = max24(средний ход 2011-2020) + Dx, ячейка 1° = площадное среднее max24 (0.25° -> 1°, common.to_1deg) + среднее Dx четырёх окружающих
узлов; для градиента 0.25° — билинейная интерполяция Dx узлов. DTR = TX - TN.
Запуск: python aggregate.py"""
import glob, json, os
import numpy as np
import xarray as xr
from common import RAW, to_1deg

R = os.path.expanduser(RAW); H = os.path.dirname(os.path.abspath(__file__))
cs = np.load(f"{R}/surface_t_cds/course_stats.npz")
c = np.load(f"{R}/climatology.npz")


def load_stat(stat, y):
    """-> (12,181,360): средний за месяц суточный экстремум, узлы lat 90..-90, lon 0..359; число дней проверено."""
    out = np.zeros((12, 181, 360)); cnt = np.zeros(12, int)
    for fn in sorted(glob.glob(f"{R}/surface_t_cds/daily/{stat}_utc+0000_{y}_m*.nc")):
        d = xr.open_dataset(fn)
        v = d["t2m"] if "t2m" in d else d[list(d.data_vars)[0]]
        tname = [k for k in v.dims if "time" in k][0]
        lat = d["latitude"].values; lon = d["longitude"].values
        a = v.transpose(tname, "latitude", "longitude").values.astype(np.float64) - 273.15
        if lat[0] < lat[-1]:
            a = a[:, ::-1, :]; lat = lat[::-1]
        assert lat[0] == 90 and lat[-1] == -90 and a.shape[1:] == (181, 360), (fn, a.shape, lat[:2])
        lon = np.where(lon < 0, lon + 360, lon); o = np.argsort(lon); a = a[:, :, o]; assert (lon[o] == np.arange(360)).all(), fn
        mon = d[tname].dt.month.values
        for m in np.unique(mon):
            s = mon == m
            out[m - 1] += a[s].sum(0); cnt[m - 1] += s.sum()
    dim = np.array([31, 28 + (y % 4 == 0), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])
    assert (cnt == dim).all(), (stat, y, cnt.tolist())
    assert np.isfinite(out).all()
    return out / cnt[:, None, None]


D = {}
for y in (2018, 2019):
    node = cs[f"node{y}"]  # (12,24,181,360)
    dx = load_stat("daily_maximum", y) - node.max(1); dn = load_stat("daily_minimum", y) - node.min(1)
    D[y] = (dx, dn)
    print(y, "Dx min/med/max", float(dx.min()), float(np.median(dx)), float(dx.max()), "Dn", float(dn.min()), float(np.median(dn)), float(dn.max()), flush=True)
Dx = (D[2018][0] + D[2019][0]) / 2; Dn = (D[2018][1] + D[2019][1]) / 2
# допуск округления упаковки CDS; отрицательные значения (> -0.05 К) -> 0
assert Dx.min() > -0.05 and Dn.max() < 0.05, (Dx.min(), Dn.max())
Dx = np.maximum(Dx, 0); Dn = np.minimum(Dn, 0)
dxy = np.abs(D[2018][0] - D[2019][0]) / 2; dny = np.abs(D[2018][1] - D[2019][1]) / 2  # оценка погрешности среднего по 2 годам (половина разности)


def nodes_to_cells(N):  # (...,181,360) lat 90..-90, lon 0.. -> (...,180,360) j=0 юг, i=0 -179.5
    S = N[..., ::-1, :]  # lat -90..90
    L = (S[..., :-1, :] + S[..., 1:, :]) / 2  # (...,180,360) между узлами по широте
    a = np.roll(L, 180, axis=-1)  # колонка i: узел lon -180+i; i-й: -180+i и -179+i
    b = np.roll(L, 179, axis=-1)
    return (a + b) / 2


def nodes_to_025(N):  # (...,181,360) -> (...,721,1440), lat 90..-90, lon 0..359.75 (билинейно)
    r = np.arange(721) / 4; r0 = np.minimum(r.astype(int), 179); tr = r - r0
    N1 = N[..., r0, :] * (1 - tr)[:, None] + N[..., r0 + 1, :] * tr[:, None]
    k = np.arange(1440) / 4; k0 = k.astype(int) % 360; tk = k - np.floor(k)
    return N1[..., k0] * (1 - tk) + N1[..., (k0 + 1) % 360] * tk


f1 = lambda a: np.stack([to_1deg(a[m]) for m in range(12)])
TX1 = f1(cs["cx10"]) + nodes_to_cells(Dx); TN1 = f1(cs["cn10"]) + nodes_to_cells(Dn); DTR1 = TX1 - TN1
TX025 = (cs["cx10"] + nodes_to_025(Dx)).astype(np.float32); TN025 = (cs["cn10"] + nodes_to_025(Dn)).astype(np.float32)
np.savez(f"{R}/climatology_t.npz", tx=TX1, dtr=DTR1, tn=TN1, tx025=TX025, dtr025=TX025 - TN025,
         dx1=nodes_to_cells(Dx), dn1=nodes_to_cells(Dn), z=c["z"], lsm=c["lsm"], z025=c["z025"], lsm025=c["lsm025"],
         years=np.array([int(v) for v in cs["years"]]))
# ---- диагностики для README ----
lm1 = c["lsm"] > 0.5; lm025 = c["lsm025"] > 0.5
q = lambda a: [round(float(v), 3) for v in np.percentile(a, [5, 50, 95])]
Dx1 = nodes_to_cells(Dx); Dn1 = nodes_to_cells(Dn)
# UTC-сутки vs местные: пик (минимум) среднего хода у границы суток UTC (часы 23, 0, 1)
hx = cs["hx10"]; hn = cs["hn10"]
nearb = lambda h: np.isin(h, (23, 0, 1))
lat025 = 90 - 0.25 * np.arange(721)
w = np.cos(np.radians(lat025))[None, :, None] * np.ones((12, 1, 1440))
num = {
    "TX1_range": [float(TX1.min()), float(TX1.max())], "DTR1_range": [float(DTR1.min()), float(DTR1.max())],
    "Dx_land_p5_50_95": q(Dx1[:, lm1]), "Dx_sea_p5_50_95": q(Dx1[:, ~lm1]), "Dn_land_p5_50_95": q(Dn1[:, lm1]), "Dn_sea_p5_50_95": q(Dn1[:, ~lm1]),
    "Dx_halfdiff_2018_2019_land_p5_50_95": q(nodes_to_cells(dxy)[:, lm1]), "Dn_halfdiff_2018_2019_land_p5_50_95": q(nodes_to_cells(dny)[:, lm1]),
    "interannual_std_max_course_10y_land_p5_50_95": q(f1(cs["sdx"])[:, lm1]), "interannual_std_min_course_10y_land_p5_50_95": q(f1(cs["sdn"])[:, lm1]),
    "cx2_minus_cx10_land_p5_50_95": q((f1(cs["cx2"]) - f1(cs["cx10"]))[:, lm1]), "cn2_minus_cn10_land_p5_50_95": q((f1(cs["cn2"]) - f1(cs["cn10"]))[:, lm1]),
    "frac_peak_hour_23_0_1UTC_land": round(float((w * (nearb(hx) & lm025[None])).sum() / (w * lm025[None]).sum()), 4),
    "frac_min_hour_23_0_1UTC_land": round(float((w * (nearb(hn) & lm025[None])).sum() / (w * lm025[None]).sum()), 4),
    "frac_peak_hour_23_0_1UTC_all": round(float((w * nearb(hx)).sum() / w.sum()), 4),
    "frac_min_hour_23_0_1UTC_all": round(float((w * nearb(hn)).sum() / w.sum()), 4),
}
# поправка по границе: Dx в узлах с пиком у границы UTC против остальных
hx_n = hx[:, ::4, ::4]; hn_n = hn[:, ::4, ::4]; lm_n = c["lsm025"][::4, ::4][None] > 0.5
num["Dx_land_nodes_peak_near_UTC_boundary_mean"] = round(float(Dx[nearb(hx_n) & lm_n].mean()), 3)
num["Dx_land_nodes_other_mean"] = round(float(Dx[~nearb(hx_n) & lm_n].mean()), 3)
num["Dn_land_nodes_min_near_UTC_boundary_mean"] = round(float(Dn[nearb(hn_n) & lm_n].mean()), 3)
num["Dn_land_nodes_other_mean"] = round(float(Dn[~nearb(hn_n) & lm_n].mean()), 3)
json.dump(num, open(H + "/numbers.json", "w"), indent=1, ensure_ascii=False)
for k, v in num.items():
    print(k, v)
