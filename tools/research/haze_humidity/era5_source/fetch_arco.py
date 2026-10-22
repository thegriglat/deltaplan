"""Суточные статистики ERA5 из ARCO (GCS Zarr, анонимно), 1° консервативный пересчёт, почасовой ряд.
Хранилище B = ar/1959-2022-1h-360x181_equiangular_with_poles_conservative.zarr, чанк = 8 часов x (37 уровней) x 360 x 181.
Чанк выровнен по суткам (24 = 3x8, эпоха 1959-01-01 00 UTC) => сутки = ровно 3 чанка, каждый скачивается один раз.
Пишет OUT/<var>[_<lev>]/<YYYY-MM-DD>.npz (атомарно: tmp + rename): mean/max/min по 24 ч, а также mean4 (00,06,12,18), mean2 (00,12), h12.
Возобновляемо: готовые сутки пропускаются; журнал jsonl — по строке на сутки (секунды, байты по запросам gcsfs).
Запуск: python fetch_arco.py <var> <уровень|-> <старт ГГГГ-ММ-ДД> <дней> <потоков> <OUT>"""
import os, sys, time, json, datetime as dt
import numpy as np
import zarr, gcsfs
from concurrent.futures import ThreadPoolExecutor

STORE = "gcp-public-data-arco-era5/ar/1959-2022-1h-360x181_equiangular_with_poles_conservative.zarr"
T0 = dt.datetime(1959, 1, 1)
NB = [0]
FAULT = float(os.environ.get("DP_FAULT", "0"))


class CountingFS(gcsfs.GCSFileSystem):
    async def _cat_file(self, path, start=None, end=None, **kw):
        r = await super()._cat_file(path, start=start, end=end, **kw)
        NB[0] += len(r)
        return r


def retry(f, n=8):
    for k in range(n):
        try:
            return f()
        except Exception as e:
            print("повтор", k, repr(e)[:100], file=sys.stderr, flush=True)
            time.sleep(2 + 4 * k)
    raise RuntimeError("не получилось")


def main():
    var, lev, start, nd, nthr, out = sys.argv[1:7]
    nd, nthr = int(nd), int(nthr)
    d0 = dt.date.fromisoformat(start)
    sub = os.path.join(out, var + ("" if lev == "-" else "_" + lev))
    os.makedirs(sub, exist_ok=True)
    fs = CountingFS(token="anon", requests_timeout=120)
    g = zarr.open_consolidated(fs.get_mapper(STORE), mode="r")
    a = g[var]
    li = None if lev == "-" else list(g["level"][:]).index(int(lev))
    days = [d0 + dt.timedelta(k) for k in range(nd)]
    todo = [d for d in days if not os.path.exists(f"{sub}/{d}.npz")]
    for f in os.listdir(sub):  # остатки оборванной записи
        if f.endswith(".tmp.npz"):
            os.remove(os.path.join(sub, f))
    print(f"всего {nd} сут., осталось {len(todo)}", flush=True)
    t_all = time.time()

    def chunk(args):
        d, j = args
        i = int((dt.datetime(d.year, d.month, d.day) - T0).total_seconds() // 3600) + 8 * j
        assert i % 8 == 0
        def get():
            if FAULT and np.random.random() < FAULT:  # имитация обрыва соединения (тест докачки)
                raise ConnectionError("имитация обрыва")
            return np.asarray(a[i:i + 8] if li is None else a[i:i + 8, li], np.float32)
        return retry(get)

    with ThreadPoolExecutor(nthr) as ex:
        # сутки по очереди (чанки суток — параллельно): оборвать можно в любой момент, готовые сутки целы
        for d in todo:
            t = time.time(); nb0 = NB[0]
            x = np.concatenate(list(ex.map(chunk, [(d, j) for j in range(3)])), 0)  # (24,360,181) [t, lon, lat]
            assert x.shape[0] == 24
            fn = f"{sub}/{d}.npz"
            np.savez_compressed(fn + ".tmp.npz", mean=x.mean(0, dtype=np.float64).astype(np.float32), max=x.max(0), min=x.min(0),
                                mean4=x[[0, 6, 12, 18]].mean(0, dtype=np.float64).astype(np.float32),
                                mean2=x[[0, 12]].mean(0, dtype=np.float64).astype(np.float32), h12=x[12])
            os.replace(fn + ".tmp.npz", fn)
            print(json.dumps({"day": str(d), "s": round(time.time() - t, 1), "MB": round((NB[0] - nb0) / 1e6, 1)}), flush=True)
    print(json.dumps({"var": var, "level": lev, "days_done": len(todo), "total_s": round(time.time() - t_all, 1), "total_MB": round(NB[0] / 1e6, 1)}), flush=True)


if __name__ == "__main__":
    main()
