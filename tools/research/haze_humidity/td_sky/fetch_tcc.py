"""ARCO-ERA5, готовая сетка 1° (conservative regrid, 1 ч): total_cloud_cover и 2m_temperature -> по ячейке 1° (как в HH-1) и местным суткам.
Источник: gs://gcp-public-data-arco-era5/ar/1959-2022-1h-360x181_equiangular_with_poles_conservative.zarr (время — часы от 1959-01-01 UTC,
оси [время, долгота 0..359, широта -90..90]); ячейка 1° HH-1 (центр -179.5+i, -89.5+j) = среднее четырёх узлов вокруг неё.
Для каждой ячейки и каждой даты D (местные сутки = UTC-сутки, сдвинутые на round(lon/15) ч):
  tcc[D]   — средняя облачность за местные 10-16 ч (6 часовых значений), доля 0..1;
  tccday   — за все 24 ч;  tmax[D] — максимум часовой T2m за местные сутки, °C.
Пишет ~/data/haze_humidity/td_sky/<год>.npz. Готовый год пропускается. Запуск: python fetch_tcc.py <год> [<год1>]"""
import os, sys, time, datetime as dt
import numpy as np
import zarr, gcsfs

Z = "gcp-public-data-arco-era5/ar/1959-2022-1h-360x181_equiangular_with_poles_conservative.zarr"
OUT = os.path.expanduser("~/data/haze_humidity/td_sky")
os.makedirs(OUT, exist_ok=True)
EPOCH = dt.datetime(1959, 1, 1)
LON = -179.5 + np.arange(360)
OFF = -np.round(LON / 15).astype(int)  # UTC-часы начала местных суток относительно UTC-полуночи даты
I0 = (np.arange(360) - 180) % 360; I1 = (np.arange(360) - 179) % 360  # индексы узлов долготы для ячейки i
BLK = 8  # дней в блоке


def hidx(d, h=0):
    return int((dt.datetime(d.year, d.month, d.day, h) - EPOCH).total_seconds() // 3600)


def cells(x):
    """[h, 360 lon, 181 lat] -> [h, 180 lat, 360 lon]: среднее 4 узлов вокруг ячейки"""
    y = (x[:, I0] + x[:, I1]) / 2          # [h,360,181]
    y = (y[:, :, :-1] + y[:, :, 1:]) / 2    # [h,360,180]
    return np.transpose(y, (0, 2, 1))


def read(a, i0, i1):
    for att in range(8):
        try:
            x = np.asarray(a[i0:i1], dtype=np.float32)
            if np.isnan(x).any():  # пропавший чанк при перегрузке сети zarr молча отдаёт NaN (fill_value) — повторить
                raise IOError("NaN в блоке")
            return x
        except Exception:
            time.sleep(3 + 4 * att)
    raise RuntimeError(f"не скачалось {i0}")


def do_year(y):
    fn = f"{OUT}/{y}.npz"
    if os.path.exists(fn):
        return
    fs = gcsfs.GCSFileSystem(token="anon", timeout=60, requests_timeout=60)
    g = zarr.open_consolidated(fs.get_mapper(Z), mode="r")
    ta, ca = g["2m_temperature"], g["total_cloud_cover"]
    n = (dt.date(y + 1, 1, 1) - dt.date(y, 1, 1)).days
    d0 = dt.date(y, 1, 1)
    os.makedirs(OUT + "/parts", exist_ok=True)
    parts = []
    for k0 in range(0, n, BLK):  # блоки сохраняются отдельно: earlyoom убивает процесс при нехватке памяти, год продолжается
        nb = min(BLK, n - k0)
        pf = f"{OUT}/parts/{y}_{k0:03d}.npz"
        parts.append(pf)
        if os.path.exists(pf):
            continue
        tcc = np.zeros((nb, 180, 360), np.float32); tccd = np.zeros_like(tcc); tmax = np.zeros_like(tcc)
        h0 = hidx(d0 + dt.timedelta(k0)) - 24; h1 = h0 + 24 * (nb + 2)
        C = cells(read(ca, h0, h1)); T = cells(read(ta, h0, h1)) - 273.15
        for i in range(360):
            for dd in range(nb):
                b = 24 + 24 * dd + OFF[i]
                tcc[dd, :, i] = C[b + 10:b + 16, :, i].mean(0)
                tccd[dd, :, i] = C[b:b + 24, :, i].mean(0)
                tmax[dd, :, i] = T[b:b + 24, :, i].max(0)
        np.savez(pf + ".tmp.npz", tcc=tcc, tccday=tccd, tmax=tmax); os.replace(pf + ".tmp.npz", pf)
        print(y, k0, flush=True)
    P = [np.load(p) for p in parts]
    tcc, tccd, tmax = (np.concatenate([p[k] for p in P]) for k in ("tcc", "tccday", "tmax"))
    np.savez(fn + ".tmp.npz", tcc=tcc, tccday=tccd, tmax=tmax)
    os.replace(fn + ".tmp.npz", fn)
    print(y, "ok", flush=True)


if __name__ == "__main__":
    for y in range(int(sys.argv[1]), int(sys.argv[-1]) + 1):
        do_year(y)
