"""Скачать все z14-тайлы OpenFreeMap, покрывающие квадрат ±20 км места. Кеш на диске, 3 потока."""
import json, math, os, sys, time, requests
from concurrent.futures import ThreadPoolExecutor
LOC = sys.argv[1] if len(sys.argv) > 1 else "aushkul"
ROOT = "/home/greg/deltaplan"
osm = json.load(open(f"{ROOT}/data/terrain/{LOC}/osm.json"))
S, W, N, E = osm["bbox_latlon"]
Z = 14
CACHE = f"/home/greg/deltaplan_data/openfreemap/tiles/{LOC}"
os.makedirs(CACHE, exist_ok=True)
tj = requests.get("https://tiles.openfreemap.org/planet", headers={"User-Agent": "deltaplan-research"}).json()
TPL = tj["tiles"][0]

def tile(lat, lon):
    n = 2 ** Z
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x, y
x0, y1 = tile(S, W); x1, y0 = tile(N, E)
tiles = [(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]
sess = requests.Session(); sess.headers["User-Agent"] = "deltaplan-research"
stat = {"retries": 0, "errors": [], "enc": {}}
def get(t):
    x, y = t
    p = f"{CACHE}/{Z}_{x}_{y}.pbf"
    if os.path.exists(p): return (t, os.path.getsize(p), 0, True)
    for a in range(4):
        try:
            r = sess.get(TPL.format(z=Z, x=x, y=y), stream=True, timeout=30)
            if r.status_code == 404:
                open(p, "wb").close(); return (t, 0, 0, False)
            r.raise_for_status()
            raw = r.raw.read(decode_content=False)
            stat["enc"][r.headers.get("Content-Encoding", "none")] = stat["enc"].get(r.headers.get("Content-Encoding", "none"), 0) + 1
            open(p, "wb").write(raw)
            return (t, len(raw), a, False)
        except Exception as e:
            stat["retries"] += 1; stat["errors"].append(f"{t}: {e}"); time.sleep(1 + a)
    return (t, -1, 4, False)
t0 = time.time()
with ThreadPoolExecutor(3) as ex: res = list(ex.map(get, tiles))
dt = time.time() - t0
fresh = [r for r in res if not r[3]]
out = {"location": LOC, "tile_url": TPL, "tilejson_version": tj.get("version"), "tiles": len(tiles), "grid": [x1-x0+1, y1-y0+1],
       "bytes_wire_total": sum(max(r[1], 0) for r in res), "empty_tiles": sum(1 for r in res if r[1] == 0),
       "failed": sum(1 for r in res if r[1] < 0), "fresh_downloaded": len(fresh), "cold_seconds": round(dt, 1),
       "retries": stat["retries"], "errors": stat["errors"][:10], "content_encoding": stat["enc"], "threads": 3,
       "x_range": [x0, x1], "y_range": [y0, y1]}
os.makedirs("results", exist_ok=True)
json.dump(out, open(f"results/fetch_{LOC}.json", "w"), indent=1)
print(out)
