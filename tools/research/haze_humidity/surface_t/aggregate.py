"""RAW/t2m/*.npz -> RAW/climatology_t.npz: TX, DTR по месяцам (1° и 0.25°), поправка недобора, ошибка выборки; Z/lsm из HH-1.
Данные — выборка дней (fetch.py): 3-часовые сроки, годы Y, дни SAMPLE_DAYS месяца. Поправка недобора (8 сроков -> 24 срока) —
по часовому году HY (1 день в месяце), по ячейке-месяцу 0.25°, затем усреднение в 1°; добавляется ко всем годам.
Запуск: python aggregate.py <часовой_год>"""
import glob, os, sys
import numpy as np
from common import RAW, to_1deg

R = os.path.expanduser(RAW)
hy = int(sys.argv[1]) if len(sys.argv) > 1 else 2015
by = {}
for f in glob.glob(f"{R}/t2m/*_s3.npz"):
    b = os.path.basename(f); by.setdefault(int(b[:4]), {})[int(b[6:8])] = f
years = sorted(y for y, v in by.items() if len(v) == 12)
print("годы", years, flush=True)
assert years and all(os.path.exists(f"{R}/t2m/{hy}_m{m:02d}_s1.npz") for m in range(1, 13))
shp = (12, 721, 1440)
sx = np.zeros(shp); sn = np.zeros(shp); sx2 = np.zeros(shp); sn2 = np.zeros(shp); nd = np.zeros(12)
for y in years:
    for m in range(1, 13):
        d = np.load(by[y][m])
        sx[m - 1] += d["tx8"]; sn[m - 1] += d["tn8"]; sx2[m - 1] += d["tx28"]; sn2[m - 1] += d["tn28"]; nd[m - 1] += d["nd"]
N = nd[:, None, None]
tx8 = sx / N; tn8 = sn / N
vx = np.maximum(sx2 / N - tx8 ** 2, 0)
se_tx = np.sqrt(vx / N)  # ошибка среднего по выборке (дни считаются независимыми; разнос 6 суток)
hx8 = np.zeros(shp); hn8 = np.zeros(shp); hx24 = np.zeros(shp); hn24 = np.zeros(shp)
for m in range(1, 13):
    d = np.load(f"{R}/t2m/{hy}_m{m:02d}_s1.npz")
    hx8[m - 1] = d["tx8"] / d["nd"]; hn8[m - 1] = d["tn8"] / d["nd"]; hx24[m - 1] = d["tx24"] / d["nd"]; hn24[m - 1] = d["tn24"] / d["nd"]
c_tx = hx24 - hx8   # >= 0 : недобор максимума
c_tn = hn24 - hn8   # <= 0 : недобор минимума
TX = tx8 + c_tx
DTR = (tx8 - tn8) + (c_tx - c_tn)
f1 = lambda a: np.stack([to_1deg(a[m]) for m in range(12)])
TX1, DTR1, cx1, cn1, se1 = f1(TX), f1(DTR), f1(c_tx), f1(c_tn), f1(se_tx)
c = np.load(f"{R}/climatology.npz")
np.savez(f"{R}/climatology_t.npz", tx=TX1, dtr=DTR1, tx025=TX.astype(np.float32), dtr025=DTR.astype(np.float32), ctx1=cx1, ctn1=cn1, se_tx1=se1,
         z=c["z"], lsm=c["lsm"], z025=c["z025"], lsm025=c["lsm025"], years=np.array([min(years), max(years)]), nyears=len(years), nd=nd)
lm = c["lsm"] > 0.5
print("дней в месяце", nd.min(), nd.max(), "TX", TX1.min(), TX1.max(), "DTR", DTR1.min(), DTR1.max())
print("поправка TX мин/сред/макс", cx1.min(), cx1.mean(), cx1.max(), "TN", cn1.min(), cn1.mean(), cn1.max())
print("ошибка выборки TX (сухопутные ячейки), К: медиана", np.median(se1[:, lm]), "95%", np.percentile(se1[:, lm], 95), "макс", se1[:, lm].max())
