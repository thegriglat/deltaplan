"""Скачивание ARCO-ERA5 (Google Cloud, анонимно): 2m_dewpoint_temperature, 00 и 12 UTC каждого дня.
Среднее 00+12 UTC гасит суточную гармонику (разнос 12 ч) -> оценка среднесуточной Td.
Пишет RAW/daily/<год>.npz: td1[день,180,360] (°C, среднее по ячейке 1°), msum025[12,721,1440] и mcnt[12] (суммы дневных
значений 0.25° по месяцам, для регрессии по высоте). Возобновляемо: готовый год пропускается.
Запуск: python fetch.py 1991 2020 [процессов]"""
import os, sys, time, datetime as dt
import numpy as np
from concurrent.futures import ThreadPoolExecutor
import zarr, gcsfs
from common import ARCO, RAW, to_1deg

OUT = os.path.expanduser(RAW) + "/daily"
os.makedirs(OUT, exist_ok=True)
EPOCH = dt.datetime(1900, 1, 1)


def hidx(d, hour):
    return int((dt.datetime(d.year, d.month, d.day, hour) - EPOCH).total_seconds() // 3600)


def do_year(y):
    fn = f"{OUT}/{y}.npz"
    if os.path.exists(fn):
        return y
    fs = gcsfs.GCSFileSystem(token="anon")
    a = zarr.open_consolidated(fs.get_mapper(ARCO), mode="r")["2m_dewpoint_temperature"]
    days = [dt.date(y, 1, 1) + dt.timedelta(k) for k in range((dt.date(y + 1, 1, 1) - dt.date(y, 1, 1)).days)]

    def get(d):
        for att in range(6):
            try:
                f = (a[hidx(d, 0)].astype(np.float64) + a[hidx(d, 12)].astype(np.float64)) / 2 - 273.15
                return f
            except Exception:
                time.sleep(2 + 3 * att)
        raise RuntimeError(f"не скачалось {d}")

    td1 = np.zeros((len(days), 180, 360), np.float32)
    msum = np.zeros((12, 721, 1440), np.float64)
    mcnt = np.zeros(12, int)
    with ThreadPoolExecutor(10) as ex:
        for k, f in enumerate(ex.map(get, days)):
            td1[k] = to_1deg(f)
            msum[days[k].month - 1] += f
            mcnt[days[k].month - 1] += 1
    np.savez(fn + ".tmp.npz", td1=td1, msum025=msum.astype(np.float32), mcnt=mcnt)
    os.replace(fn + ".tmp.npz", fn)
    print(y, "ok", flush=True)
    return y


if __name__ == "__main__":
    y0, y1 = int(sys.argv[1]), int(sys.argv[2])
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    from multiprocessing import Pool
    with Pool(n) as p:
        for y in p.imap_unordered(do_year, range(y0, y1 + 1)):
            pass
