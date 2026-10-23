"""Полнота докачки ERA5 из ARCO (HH-18): печатает остаток по наборам и итог complete=0|1.
Наборы в ~/data/haze_humidity/era5_arco: t2m 2018-2019 (+ суточный ход по месяцам), temperature_700 2019, u/v 700 2018-2019.
Читаются все npz (mean,max,min,mean4,mean2,h12; форма (360,181)); NaN допускаются в доле <= 1e-3 ячеек (запас)."""
import os, sys, datetime as dt
import numpy as np
O = os.path.expanduser(os.environ.get("DP_ARCO", "~/data/haze_humidity/era5_arco"))
SETS = [("2m_temperature", "2018-01-01", 730), ("temperature_700", "2019-01-01", 365),
        ("u_component_of_wind_700", "2018-01-01", 730), ("v_component_of_wind_700", "2018-01-01", 730)]
KEYS = ("mean", "max", "min", "mean4", "mean2", "h12")
ok = True
for name, st, n in SETS:
    d0 = dt.date.fromisoformat(st); miss = []; bad = []
    for k in range(n):
        f = f"{O}/{name}/{d0 + dt.timedelta(k)}.npz"
        if not os.path.exists(f):
            miss.append(str(d0 + dt.timedelta(k))); continue
        try:
            z = np.load(f)
            for key in KEYS:
                a = z[key]
                assert a.shape == (360, 181) and np.isnan(a).mean() <= 1e-3
        except Exception as e:
            bad.append((f.rsplit("/", 1)[1], repr(e)[:60]))
    print(f"{name}: есть {n - len(miss)}/{n}, нет {len(miss)}, битых {len(bad)}" + (f" (первое нет {miss[0]})" if miss else ""), bad[:3])
    ok &= not miss and not bad
for y in (2018, 2019):
    f = f"{O}/2m_temperature_diurnal_{y}.npz"
    try:
        z = np.load(f); good = z["mean"].shape == (12, 24, 360, 181) and list(z["n"]) == [31, 29 if y % 4 == 0 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] and np.isfinite(z["mean"]).all()
    except Exception:
        good = False
    print(f"суточный ход {y}: {'ok' if good else 'нет/неполон'}"); ok &= good
print(f"complete={int(ok)}")
