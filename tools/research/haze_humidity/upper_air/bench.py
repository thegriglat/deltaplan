"""Замер скорости чтения ERA5 (WB2/ARCO 6h 1440x721, 13 уровней) на 700 гПа: python bench.py <потоков> <чтений>"""
import sys, time
import numpy as np, zarr, gcsfs
from concurrent.futures import ThreadPoolExecutor
from common import ARCO6
nt, n = int(sys.argv[1]), int(sys.argv[2])
fs = gcsfs.GCSFileSystem(token="anon", requests_timeout=120)
g = zarr.open_consolidated(fs.get_mapper(ARCO6), mode="r")
lv = list(g["level"][:]).index(700)
a = g["temperature"]
def f(i):
    t = time.time(); a[50000 + i, lv]; return time.time() - t
t0 = time.time()
with ThreadPoolExecutor(nt) as ex:
    r = list(ex.map(f, range(n)))
print(f"{nt} потоков, {n} чтений: {time.time()-t0:.1f} с, на чтение в потоке {np.mean(r):.1f} с", flush=True)
