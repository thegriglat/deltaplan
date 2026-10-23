"""Сверка HH6 для мест игры. sites.csv: место,lat,lon,месяц,wr,z700_m,z_cell_m,gain_per_km,trop_m,hcc,hcc_med,hcc_lt01,hcc_sem,v10_ms.
wr/trop — из бина HH6, z700 — HH2 по месяцу, z_cell — блок Z из HH1, hcc* — ERA5 (бин и upper_misc_clim.npz).
Запуск: python sites.py"""
import csv, os, struct
import numpy as np, brotli
from common import RAW

H = os.path.dirname(os.path.abspath(__file__)); D = H + "/../../../../data/climate/"
R = os.path.expanduser(RAW)
SITES = {"altai": (51.87, 85.87), "ongudai": (50.79, 86.13), "askarovo": (53.26, 58.54), "aushkul": (54.72, 59.69),
         "crimea": (44.95, 35.12), "Darab": (28.75, 54.55), "Cairns": (-16.92, 145.77)}


def bil(a, lat, lon):
    fj = lat + 89.5; fi = lon + 179.5
    j0 = int(np.floor(fj)); i0 = int(np.floor(fi)); tj = fj - j0; ti = fi - i0
    j0 = min(max(j0, 0), 178); i0 %= 360; i1 = (i0 + 1) % 360
    return a[..., j0, i0] * (1 - tj) * (1 - ti) + a[..., j0, i1] * (1 - tj) * ti + a[..., j0 + 1, i0] * tj * (1 - ti) + a[..., j0 + 1, i1] * tj * ti


b = open(D + "upper_misc_1deg.bin", "rb").read()
wrs, trs, hcs = struct.unpack_from("<fff", b, 32); raw = brotli.decompress(b[64:])
a = np.frombuffer(raw, "<i2").reshape(3, 12, 180, 360).astype(float)
wr, trop, hcc = a[0] * wrs, a[1] * trs, a[2] * hcs
g = open(D + "dew_point_1deg.bin", "rb").read()
zs = struct.unpack_from("<f", g, 44)[0]
n3 = 12 * 180 * 360
zc = np.frombuffer(brotli.decompress(g[64:]), "<i2")[2 * n3:].reshape(180, 360).astype(float) * zs
import glob
c = dict(np.load(R + "/upper_misc_cds_clim.npz")); v = c["v10"]
# медиана и доля дней hcc<0.1 — по выборке ARCO (сутки 1 и 13 каждого месяца, среднее 00+12 UTC, 2011–2020); в сетке — месячные средние CDS
smp = [[] for _ in range(12)]
for f in sorted(glob.glob(R + "/upper_misc/*/*.npz")):
    smp[int(os.path.basename(f)[:2]) - 1].append(np.load(f)["hcc"])
smp = [np.array(a) for a in smp]
c["hcc_med"] = np.array([np.nanmedian(a, 0) for a in smp]); c["hcc_lt01"] = np.array([np.nanmean(np.where(np.isnan(a), np.nan, a < 0.1), 0) for a in smp]); c["n_smp"] = len(smp[0])
ua = open(D + "upper_air_1deg.bin", "rb").read()
uzs, uzo = struct.unpack_from("<ff", ua, 40); assert struct.unpack_from("<I", ua, 56)[0] > 0  # не заглушка HH2
z700 = np.frombuffer(brotli.decompress(ua[64:]), "<i2")[12 * 180 * 360:].reshape(12, 180, 360).astype(float) * uzs + uzo
rows = []
for k, (lat, lon) in SITES.items():
    zcell = float(bil(zc, lat, lon))
    for m in range(12):
        w = float(bil(wr[m], lat, lon)); Z700 = float(bil(z700[m], lat, lon)); gain = (w - 1) / (max(Z700 - zcell, 500.0) / 1000)
        rows.append([k, lat, lon, m + 1, round(w, 3), round(Z700), round(zcell, 1), round(gain, 3), round(float(bil(trop[m], lat, lon))),
                     round(float(bil(hcc[m], lat, lon)), 3), round(float(bil(c["hcc_med"][m], lat, lon)), 3),
                     round(float(bil(c["hcc_lt01"][m], lat, lon)), 3), round(float(bil(c["hcc_sem"][m], lat, lon)), 3),
                     round(float(bil(v[m], lat, lon)), 2)])
with open(H + "/sites.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["место", "lat", "lon", "месяц", "wr", "z700_m", "z_cell_m", "gain_per_km", "trop_m", "hcc", "hcc_med", "hcc_lt01", "hcc_sem", "v10_ms"])
    w.writerows(rows)
for k in SITES:
    r = [x for x in rows if x[0] == k]
    print(k, "zcell", r[0][6], "hcc", [x[9] for x in r], "med", [x[10] for x in r], "<0.1", [x[11] for x in r], "v10", [x[13] for x in r])
