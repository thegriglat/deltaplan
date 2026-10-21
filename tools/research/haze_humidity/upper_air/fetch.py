"""Скачивание ARCO-ERA5 (Google Cloud, анонимно): temperature и geopotential на 700 гПа, 00 и 12 UTC каждого дня.
Среднее 00+12 UTC гасит суточную гармонику. Пишет RAW/upper_air/<год>.npz: t1[день,180,360] (°C) и z1[день,180,360] (м),
среднее по ячейке 1°. Возобновляемо: готовый год пропускается. Запуск: python fetch.py 2011 2020 [потоков_на_год] [лет_параллельно]"""
import os, sys, time, datetime as dt
import numpy as np
from concurrent.futures import ThreadPoolExecutor
import zarr, gcsfs
from common import ARCO, RAW, to_1deg

OUT = os.path.expanduser(RAW) + "/upper_air"
os.makedirs(OUT, exist_ok=True)
EPOCH = dt.datetime(1900, 1, 1)


def hidx(d, hour):
    return int((dt.datetime(d.year, d.month, d.day, hour) - EPOCH).total_seconds() // 3600)


def do_year(args):
    y, nthr = args
    fn = f"{OUT}/{y}.npz"
    if os.path.exists(fn):
        return y
    # requests_timeout — аргумент gcsfs (timeout в GCSFileSystem в этой версии ничего не делает)
    fs = gcsfs.GCSFileSystem(token="anon", requests_timeout=120)
    g = zarr.open_consolidated(fs.get_mapper(ARCO), mode="r")
    lv = list(g["level"][:]).index(700)
    at, az = g["temperature"], g["geopotential"]
    days = [dt.date(y, 1, 1) + dt.timedelta(k) for k in range((dt.date(y + 1, 1, 1) - dt.date(y, 1, 1)).days)]

    def get(d):
        for att in range(8):
            try:
                t = (at[hidx(d, 0), lv].astype(np.float64) + at[hidx(d, 12), lv].astype(np.float64)) / 2 - 273.15
                z = (az[hidx(d, 0), lv].astype(np.float64) + az[hidx(d, 12), lv].astype(np.float64)) / 2 / 9.80665
                return to_1deg(t), to_1deg(z)
            except Exception:
                time.sleep(2 + 3 * att)
        raise RuntimeError(f"не скачалось {d}")

    t1 = np.zeros((len(days), 180, 360), np.float32)
    z1 = np.zeros((len(days), 180, 360), np.float32)
    t0 = time.time()
    with ThreadPoolExecutor(nthr) as ex:
        for k, (t, z) in enumerate(ex.map(get, days)):
            t1[k], z1[k] = t, z
            if k % 30 == 0:
                print(y, k, f"{time.time()-t0:.0f} с", flush=True)
    np.savez(fn + ".tmp.npz", t1=t1, z1=z1)
    os.replace(fn + ".tmp.npz", fn)
    print(y, "ok", f"{time.time()-t0:.0f} с", flush=True)
    return y


if __name__ == "__main__":
    y0, y1 = int(sys.argv[1]), int(sys.argv[2])
    nthr = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    npar = int(sys.argv[4]) if len(sys.argv) > 4 else 2
    from multiprocessing import Pool
    with Pool(npar) as p:
        for y in p.imap_unordered(do_year, [(y, nthr) for y in range(y0, y1 + 1)]):
            pass
