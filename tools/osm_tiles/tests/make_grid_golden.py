"""Золотая таблица сетки O1: tests/contracts/osm_tiles/grid_golden.json.

Считается эталонным Python (Band/tile_of из tools/research/osm_pack/build_tiles20.py); соседей эталон
не имеет — они считаются по тексту O1 (отдельная независимая реализация ниже).
Запуск: /home/greg/deltaplan_data/osm_pack/venv/bin/python -I tools/osm_tiles/tests/make_grid_golden.py
"""
import json
import math
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/research/osm_pack"))
import build_tiles20 as ref  # noqa: E402

DLAT = ref.DLAT


def norm_lon(lon):
    return lon if -180.0 <= lon < 180.0 else (lon + 180.0) % 360.0 - 180.0


def band_j(lat):
    return max(-500, min(499, math.floor(max(-90.0, min(90.0, lat)) / DLAT)))


def project(lat, lon):
    lon = norm_lon(lon)
    j = band_j(lat)
    bd = ref.Band.get(j)
    i = min(bd.n - 1, max(0, math.floor((lon + 180) / bd.dlon)))
    return j, i, (lon - bd.lon0(i)) * bd.kx, (lat - bd.lat0) * bd.ky


def neighbors(lat, lon):
    lon = norm_lon(lon)
    j = band_j(lat)
    out = []
    for jj in (j - 1, j, j + 1):
        if not -500 <= jj <= 499:
            continue
        bd = ref.Band.get(jj)
        ic = min(bd.n - 1, max(0, math.floor((lon + 180) / bd.dlon)))
        for d in (-1, 0, 1):
            t = [jj, (ic + d) % bd.n]
            if t not in out:
                out.append(t)
    return out


def main():
    bands = []
    for j in range(-500, 500):
        b = ref.Band.get(j)
        bands.append({"j": j, "n": b.n, "dlon": b.dlon, "kx": b.kx})
    special = [(0.0, 0.0), (0.0, -180.0), (0.0, 179.9999999), (-0.0001, -0.0001), (46.05, 14.5), (43.0, 5.0),
               (60.0, 25.0), (80.0, 100.0), (-80.0, -100.0), (89.9999, 10.0), (90.0, 0.0), (-90.0, 0.0),
               (-89.99, 179.99), (45.4, 15.1), (45.0, 180.0), (45.0, -180.0), (0.18, 0.0), (-0.18, 0.0),
               (51.5, -0.12), (43.25, 76.9), (35.68, 139.7), (-33.9, 151.2), (89.82, 0.0), (-89.82, 0.0)]
    rnd = random.Random(20261010)
    points = list(special)
    while len(points) < 420:
        lat = math.degrees(math.asin(rnd.uniform(-1, 1))) if rnd.random() < 0.5 else rnd.uniform(-90, 90)
        points.append((round(lat, 6), round(rnd.uniform(-180, 180), 6)))
    pts = []
    for lat, lon in points:
        j, i, x, y = project(lat, lon)
        pts.append({"lat": lat, "lon": lon, "j": j, "i": i, "x": x, "y": y})
    nb_pts = [p for p in special if p != (-0.0001, -0.0001)] + points[len(special):len(special) + 20]
    nbs = [{"lat": lat, "lon": lon, "tiles": neighbors(lat, lon)} for lat, lon in nb_pts]
    out = {"schema": "osmtiles-grid-golden/1", "bands": bands, "points": pts, "neighbors": nbs}
    dst = ROOT / "tests/contracts/osm_tiles/grid_golden.json"
    dst.write_text(json.dumps(out, indent=0, separators=(",", ":")) + "\n")
    print("bands", len(bands), "points", len(pts), "neighbors", len(nbs))


main()
