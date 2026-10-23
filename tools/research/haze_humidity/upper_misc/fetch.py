"""ARCO-ERA5 (анонимно): high_cloud_cover и |V10| (из 10m_u/v) в 00 и 12 UTC, выборка дней 1,13,25 каждого месяца.
Среднее двух сроков (разнос 12 ч гасит суточную гармонику); |V10| — модуль на 0.25°, потом среднее по площади до 1°.
Пишет RAW/upper_misc/<год>/<мм>-<дд>.npz: hcc[180,360], spd[180,360] (float32). Возобновляемо: готовый день пропускается.
Запуск: python fetch.py 2011 2020 [потоков]"""
import os, sys, time, datetime as dt
import numpy as np
from concurrent.futures import ThreadPoolExecutor
import zarr, gcsfs
from common import ARCO, RAW, to_1deg

OUT = os.path.expanduser(RAW) + "/upper_misc"
EPOCH = dt.datetime(1900, 1, 1)
DAYS = (1, 13, 25)
HOURS = (0, 12)


def hidx(d, hour):
    return int((dt.datetime(d.year, d.month, d.day, hour) - EPOCH).total_seconds() // 3600)


if __name__ == "__main__":
    y0, y1 = int(sys.argv[1]), int(sys.argv[2])
    nthr = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    fs = gcsfs.GCSFileSystem(token="anon", requests_timeout=120)
    g = zarr.open_consolidated(fs.get_mapper(ARCO), mode="r")
    ah, au, av = g["high_cloud_cover"], g["10m_u_component_of_wind"], g["10m_v_component_of_wind"]
    todo = [dt.date(y, m, d) for d in DAYS for y in range(y0, y1 + 1) for m in range(1, 13)]  # по проходам: можно остановить в любой момент
    t0 = time.time()
    done = [0]

    def get(d):
        fn = f"{OUT}/{d.year}/{d.month:02d}-{d.day:02d}.npz"
        if os.path.exists(fn):
            return
        os.makedirs(os.path.dirname(fn), exist_ok=True)
        for att in range(8):
            try:
                h = np.zeros((721, 1440)); s = np.zeros((721, 1440))
                for hr in HOURS:
                    i = hidx(d, hr)
                    h += ah[i]; s += np.hypot(au[i].astype(np.float64), av[i].astype(np.float64))
                h /= len(HOURS); s /= len(HOURS)
                np.savez(fn + ".tmp.npz", hcc=to_1deg(h).astype(np.float32), spd=to_1deg(s).astype(np.float32))
                os.replace(fn + ".tmp.npz", fn)
                done[0] += 1
                print(d, f"{done[0]}/{len(todo)} {time.time()-t0:.0f} с", flush=True)
                return
            except Exception as e:
                print("повтор", d, att, repr(e)[:80], flush=True)
                time.sleep(2 + 3 * att)
        raise RuntimeError(f"не скачалось {d}")

    with ThreadPoolExecutor(nthr) as ex:
        list(ex.map(get, todo))
    print("готово", flush=True)
