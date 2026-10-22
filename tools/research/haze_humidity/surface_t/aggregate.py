"""CDS monthly-means by_hour_of_day (2m_temperature, 1991-2020) + поправка недобора по часовым ERA5 -> RAW/climatology_t.npz.
1) C[m,h] — средний суточный ход месяца m по 24 часам UTC, среднее по 30 годам. Максимум/минимум хода по 24 часам не зависит от
   разбиения на сутки (ход периодичен), местные сутки не нужны.
2) Максимум среднего хода ниже среднего суточного максимума (дни расходятся по фазе и амплитуде): поправка Dx >= 0, Dn <= 0.
   Оценка: в годах CORR_YEARS по 4 МЕСТНЫХ дня в месяц (cds_fetch_hourly.py, часовые поля 0.25°):
   Dx = среднее(суточный максимум дня) - max24(ход CDS того же года-месяца); Dn аналогично. Среднее по дням и годам, ячейка 0.25°.
   TX = max24(C) + Dx; TN = min24(C) + Dn; DTR = TX - TN. Затем площадное усреднение 0.25° -> 1° (common.to_1deg).
   Ошибка выборки Dx: std дней / sqrt(N дней), по 1° — среднее по 16 ячейкам без учёта корреляции (консервативно).
Запуск: python aggregate.py   (RAW/surface_t_cds/t2m_<год>.nc 1991..2020, RAW/surface_t_cds/hourly/*.npz, RAW/climatology.npz из HH-1)"""
import os
import numpy as np
import xarray as xr
from common import RAW, to_1deg

R = os.path.expanduser(RAW)
YEARS = list(range(1991, 2021))
CORR_YEARS = [2005, 2011, 2016]
NOCORR = os.environ.get('NOCORR') == '1'  # отладка: без поправки (не для выпуска)
acc = np.zeros((12, 24, 721, 1440), np.float64)
yx = {}; yn = {}
for y in YEARS:
    d = xr.open_dataset(f"{R}/surface_t_cds/t2m_{y}.nc")
    assert d.t2m.shape == (288, 721, 1440) and float(d.latitude[0]) == 90.0 and float(d.longitude[0]) == 0.0, y
    assert (d.valid_time.dt.month.values == np.repeat(np.arange(1, 13), 24)).all() and (d.valid_time.dt.hour.values == np.tile(np.arange(24), 12)).all()
    a = d.t2m.values.reshape(12, 24, 721, 1440).astype(np.float32) - 273.15
    assert np.isfinite(a).all(), y
    acc += a
    if y in CORR_YEARS:
        yx[y] = a.max(1); yn[y] = a.min(1)
    print("год", y, flush=True)
C = (acc / len(YEARS)).astype(np.float32)
cx24 = C.max(1); cn24 = C.min(1)
sx = np.zeros((12, 721, 1440)); sn = np.zeros_like(sx); sx2 = np.zeros_like(sx); sn2 = np.zeros_like(sx); nd = 0
for y in CORR_YEARS:
    for m in range(1, 13):
        if NOCORR:
            continue
        z = np.load(f"{R}/surface_t_cds/hourly/{y}_m{m:02d}.npz")
        dx = z["mx"] - yx[y][m - 1][None]; dn = z["mn"] - yn[y][m - 1][None]
        sx[m - 1] += dx.sum(0); sn[m - 1] += dn.sum(0); sx2[m - 1] += (dx.astype(np.float64) ** 2).sum(0); sn2[m - 1] += (dn.astype(np.float64) ** 2).sum(0)
    nd += 4
nd = max(nd, 1)
Dx = (sx / nd).astype(np.float32); Dn = (sn / nd).astype(np.float32)
sd_x = np.sqrt(np.maximum(sx2 / nd - Dx.astype(np.float64) ** 2, 0)); se_x = sd_x / np.sqrt(nd)
TX = cx24 + Dx; TN = cn24 + Dn
f1 = lambda a: np.stack([to_1deg(a[m]) for m in range(12)])
TX1 = f1(TX); TN1 = f1(TN); DTR1 = TX1 - TN1
Dx1 = f1(Dx); Dn1 = f1(Dn); cx1 = f1(cx24); cn1 = f1(cn24); se1 = f1(se_x)
c = np.load(f"{R}/climatology.npz")
np.savez(f"{R}/climatology_t.npz", tx=TX1, dtr=DTR1, tn=TN1, tx025=TX.astype(np.float32), dtr025=(TX - TN).astype(np.float32),
         dx1=Dx1, dn1=Dn1, cx24_1=cx1, cn24_1=cn1, se_dx1=se1, z=c["z"], lsm=c["lsm"], z025=c["z025"], lsm025=c["lsm025"],
         years=np.array([YEARS[0], YEARS[-1]]), nyears=len(YEARS), ndays=nd)
lm = c["lsm"] > 0.5
q = lambda a: [round(float(v), 3) for v in np.percentile(a, [5, 50, 95])]
print("TX", TX1.min(), TX1.max(), "DTR", DTR1.min(), DTR1.max())
print("поправка Dx (1°) суша p5/p50/p95", q(Dx1[:, lm]), "море", q(Dx1[:, ~lm]))
print("поправка Dn суша", q(Dn1[:, lm]), "море", q(Dn1[:, ~lm]))
print("ошибка выборки Dx суша p5/p50/p95", q(se1[:, lm]), "дней на месяц", nd)
