"""Замер скорости чтения ARCO (1h, 0.25°, одиночный уровень): python bench.py <потоков> <чтений>"""
import sys, time, numpy as np, zarr, gcsfs
from concurrent.futures import ThreadPoolExecutor
from common import ARCO
nt, n = int(sys.argv[1]), int(sys.argv[2])
fs = gcsfs.GCSFileSystem(token="anon", requests_timeout=60)
g = zarr.open_consolidated(fs.get_mapper(ARCO), mode="r")
names = ["high_cloud_cover", "10m_u_component_of_wind", "10m_v_component_of_wind"]
print({k: (g[k].shape, g[k].chunks, g[k].dtype) for k in names}, flush=True)
def f(i):
    t = time.time(); g[names[i % 3]][600000 + 24 * (i // 3)]; return time.time() - t
t0 = time.time()
with ThreadPoolExecutor(nt) as ex: r = list(ex.map(f, range(n)))
print(f"{nt} потоков, {n} чтений: {time.time()-t0:.1f} с, {n/(time.time()-t0):.2f} чт/с, в потоке {np.mean(r):.1f} с", flush=True)
