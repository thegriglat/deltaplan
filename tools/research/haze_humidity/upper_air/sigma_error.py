"""Погрешность σ T700 по 2 годам (2018–2019) в точках игры (ближайший узел 1°). Выход sigma_error.json.
(а) σ месяца по 2018 и по 2019 отдельно -> разброс между годами (оценка ошибки σ короткого ряда);
(б) смещение среднего месяца: среднее 2018–2019 минус среднее 2011–2020 по месячным средним T700 (вклад в σ: σ считается вокруг
    среднего двух лет, а не десяти). Дни: CDS daily 2018, 2019 H1; ARCO-1° для 2019 H2 (HH-18)."""
import glob, json, os
import numpy as np, xarray as xr
from common import RAW
R = os.path.expanduser(RAW)
SITES = {"altai": (51.87, 85.87), "ongudai": (50.79, 86.13), "askarovo": (53.26, 58.54), "aushkul": (54.72, 59.69),
         "crimea": (44.95, 35.12), "dry_darab": (28.75, 54.55), "wet_cairns": (-16.92, 145.77)}
def idx(lat, lon): return int(round(lat + 90)), int(round(lon)) % 360   # узел (lat -90..90, lon 0..359)
days = {}  # дата -> (site->T K)
def pick(a, k):  # a (181 lat, 360 lon)
    j, i = idx(*SITES[k]); return float(a[j, i])
for f in sorted(glob.glob(R + "/upper_air_cds_daily/[12]*.nc")):
    d = xr.open_dataset(f); v = d["t"].squeeze(drop=True); tn = "valid_time" if "valid_time" in v.coords else "time"
    v = v.sortby("latitude"); v = v.assign_coords(longitude=v.longitude % 360).sortby("longitude")
    for n, t in enumerate(v[tn].values):
        days[str(t)[:10]] = {k: pick(v.values[n], k) for k in SITES}
    d.close()
for f in sorted(glob.glob(R + "/era5_arco/temperature_700/2019-*.npz")):
    day = os.path.basename(f)[:10]
    if day not in days:
        a = np.load(f)["mean"].T; days[day] = {k: pick(a, k) for k in SITES}
out = {"n_days": len(days), "sites": {}}
for k in SITES:
    rows = {}
    for yr in ("2018", "2019"):
        rows[yr] = [float(np.std([days[d][k] for d in days if d[:4] == yr and int(d[5:7]) == m])) for m in range(1, 13)]
    both = [float(np.std([days[d][k] for d in days if int(d[5:7]) == m])) for m in range(1, 13)]
    out["sites"][k] = {"sd_2018": rows["2018"], "sd_2019": rows["2019"], "sd_both": both}
m10 = xr.open_dataset(R + "/upper_air_cds/2011_2020.nc"); v = m10["t"].squeeze(drop=True)
tn = "valid_time" if "valid_time" in v.coords else "time"; v = v.sortby("latitude"); v = v.assign_coords(longitude=v.longitude % 360).sortby("longitude")
tt = v[tn].values.astype("datetime64[M]"); yy = tt.astype("datetime64[Y]").astype(int) + 1970; mm = tt.astype(int) % 12
for k in SITES:
    j, i = idx(*SITES[k]); s = v.values[:, j, i]
    ym = np.array([[s[(yy == y) & (mm == m)].mean() for m in range(12)] for y in range(2011, 2021)])  # (10, 12) по годам
    out["sites"][k]["bias_2yr_vs_10yr_k"] = (ym[[7, 8]].mean(0) - ym.mean(0)).tolist()
    out["sites"][k]["interannual_sd_month_k"] = ym.std(0, ddof=1).tolist()
S = out["sites"]
for k in S:
    a, b = np.array(S[k]["sd_2018"]), np.array(S[k]["sd_2019"])
    S[k]["rel_diff_2018_2019_median"] = float(np.median(np.abs(a - b) / ((a + b) / 2)))
    S[k]["max_abs_bias_k"] = float(np.abs(S[k]["bias_2yr_vs_10yr_k"]).max())
json.dump(out, open(os.path.dirname(os.path.abspath(__file__)) + "/sigma_error.json", "w"), indent=1)
for k in S: print(k, "σ 2018 vs 2019 отн.разн. (медиана по мес.) %.2f; |смещение среднего 2 лет| max %.2f K; межгод. СКО мес. T700 ср. %.2f K" % (S[k]["rel_diff_2018_2019_median"], S[k]["max_abs_bias_k"], np.mean(S[k]["interannual_sd_month_k"])))
