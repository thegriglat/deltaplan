"""Высота долины места: 10-й перцентиль рельефа в радиусе 10 км (как в игре: valley_percentile 0.1,
atmosphere.json ground.reference_radius_m 10000) по AWS Terrain Tiles (terrarium, z10, открытые данные
https://registry.opendata.aws/terrain-tiles/). Результат -> valleys.json. Запуск: python valleys.py"""
import io, json, math, os, urllib.request
import numpy as np
from PIL import Image

SITES = {  # имя: (lat, lon)
    "altai": (51.87, 85.87), "ongudai": (50.79, 86.13), "askarovo": (53.26, 58.54), "aushkul": (54.72, 59.69),
    "training_island": (43.2, 34.0), "volcano_island": (-27.1, -109.35),
    "dry_darab_iran": (28.85, 54.57), "wet_cairns_au": (-16.65, 145.57),
}
Z = 10
CACHE = os.path.expanduser("~/data/haze_humidity/terrarium")
os.makedirs(CACHE, exist_ok=True)


def tile(x, y):
    fn = f"{CACHE}/{Z}_{x}_{y}.png"
    if not os.path.exists(fn):
        url = f"https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{Z}/{x}/{y}.png"
        with urllib.request.urlopen(url, timeout=60) as r:
            open(fn, "wb").write(r.read())
    a = np.asarray(Image.open(fn).convert("RGB"), dtype=np.float64)
    return a[..., 0] * 256 + a[..., 1] + a[..., 2] / 256 - 32768


def xy(lat, lon):
    n = 2 ** Z
    x = (lon + 180) / 360 * n
    y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return x, y


def valley(lat, lon, r_km=10.0, pct=10):
    x0, y0 = xy(lat, lon)
    ppx = 256 * 2 ** Z / (2 * math.pi * 6371.0088 * math.cos(math.radians(lat)))  # пикселей на км
    r = r_km * ppx
    xs = range(int(math.floor(x0 - r / 256)), int(math.floor(x0 + r / 256)) + 1)
    ys = range(int(math.floor(y0 - r / 256)), int(math.floor(y0 + r / 256)) + 1)
    vals = []
    for ty in ys:
        for tx in xs:
            t = tile(tx % 2 ** Z, ty)
            yy, xx = np.mgrid[0:256, 0:256]
            d = np.hypot(tx * 256 + xx - x0 * 256, ty * 256 + yy - y0 * 256)
            vals.append(t[d <= r])
    v = np.concatenate(vals)
    return float(np.percentile(v, pct)), float(v.mean()), float(v.min()), float(v.max())


if __name__ == "__main__":
    out = {}
    for k, (la, lo) in SITES.items():
        p, m, mn, mx = valley(la, lo)
        out[k] = {"lat": la, "lon": lo, "valley_p10_m": round(p, 1), "mean_m": round(m, 1), "min_m": round(mn, 1), "max_m": round(mx, 1)}
        print(k, out[k])
    json.dump(out, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "valleys.json"), "w"), indent=1)
