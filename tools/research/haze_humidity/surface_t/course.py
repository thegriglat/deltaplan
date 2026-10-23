"""Этап A: средний суточный ход T2m (CDS monthly-means by_hour_of_day, 0.25°, 24 срока UTC) 2011-2020 -> RAW/surface_t_cds/course_stats.npz.
Для каждого месяца и ячейки 0.25°:
  cx10, cn10  — максимум/минимум среднего хода (среднего по 10 годам 2011-2020), °C;
  cx2, cn2    — то же по среднему ходу 2018-2019 (годы суточных статистик, нужны для поправки недобора);
  sdx, sdn    — межгодовое std максимума/минимума среднего хода по 10 годам (для оценки погрешности короткого ряда);
  hx10, hn10  — час UTC максимума/минимума среднего хода (10 лет);
  node2018/19 — средний ход года в узлах 1° (lat 90..-90, lon 0..359): (12,24,181,360) — для поправки в тех же узлах, что у daily-statistics.
Запуск: python course.py"""
import os
import numpy as np
import xarray as xr
from common import RAW

R = os.path.expanduser(RAW)
YEARS = list(range(2011, 2021)); Y2 = (2018, 2019)
acc = np.zeros((12, 24, 721, 1440), np.float64); acc2 = np.zeros_like(acc); nodes = {}
s1x = np.zeros((12, 721, 1440)); s2x = np.zeros_like(s1x); s1n = np.zeros_like(s1x); s2n = np.zeros_like(s1x)
for y in YEARS:
    d = xr.open_dataset(f"{R}/surface_t_cds/t2m_{y}.nc")
    assert d.t2m.shape == (288, 721, 1440) and float(d.latitude[0]) == 90.0 and float(d.longitude[0]) == 0.0, y
    assert (d.valid_time.dt.month.values == np.repeat(np.arange(1, 13), 24)).all() and (d.valid_time.dt.hour.values == np.tile(np.arange(24), 12)).all()
    a = d.t2m.values.reshape(12, 24, 721, 1440).astype(np.float32) - 273.15
    assert np.isfinite(a).all(), y
    acc += a
    if y in Y2:
        acc2 += a; nodes[y] = a[:, :, ::4, ::4].copy()
    mx = a.max(1).astype(np.float64); mn = a.min(1).astype(np.float64)
    s1x += mx; s2x += mx ** 2; s1n += mn; s2n += mn ** 2
    print("год", y, flush=True)
n = len(YEARS)
C = (acc / n).astype(np.float32); C2 = (acc2 / len(Y2)).astype(np.float32)
sd = lambda s1, s2: np.sqrt(np.maximum(s2 / n - (s1 / n) ** 2, 0) * n / (n - 1)).astype(np.float32)
np.savez(f"{R}/surface_t_cds/course_stats.npz", cx10=C.max(1), cn10=C.min(1), cx2=C2.max(1), cn2=C2.min(1), sdx=sd(s1x, s2x), sdn=sd(s1n, s2n),
         hx10=C.argmax(1).astype(np.int8), hn10=C.argmin(1).astype(np.int8), node2018=nodes[2018], node2019=nodes[2019], years=np.array([YEARS[0], YEARS[-1]]))
print("готово", flush=True)
