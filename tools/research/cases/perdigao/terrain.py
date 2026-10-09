"""Perdigão: рельеф (DSM Copernicus GLO-30) и доля леса (ESA WorldCover 2021) конвейером игры.

Функции tools/terrain/fetch_dem.py (build_layer → sample_copernicus, кеш ~/.cache/deltaplan_terrain) и
fetch_landcover.py (sample_worldcover). Локация игры не заводится, tools/terrain/ не правится.
Кадр — локальная равнопромежуточная проекция игры вокруг (LAT0, LON0): x — восток, y — север (как сетка
решателя), начало — центр области. Мачты: E/N PT-TM06/ETRS89 из towers_layout.csv → lat/lon (pyproj) → тот же кадр.

  python terrain.py        → out/terrain10.npz (DSM и доля леса на сетке 10 м), out/masts.csv, out/terrain_check.md
"""
from __future__ import annotations

import csv
import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "tools" / "research" / "_legacy_terrain"))
import fetch_dem as FD            # noqa: E402
import fetch_landcover as FL      # noqa: E402

OUT = HERE / "out"
TOWERS = ROOT / "tools/research/data/perdigao/towers_layout.csv"
PT_TM06 = ("+proj=tmerc +lat_0=39.66825833333333 +lon_0=-8.133108333333334 +k=1 +x_0=0 +y_0=0 "
           "+ellps=GRS80 +units=m +no_defs")          # EPSG:3763 PT-TM06/ETRS89
CENTER_TM = (33900.0, 4800.0)       # центр долины между грядами (PT-TM06, м)
SIZE_M = 6000.0                     # сторона области, м
FINE = 10.0                         # шаг выборки DSM/леса, м (dx прогонов кратен 10)
SMOOTH_SIGMA_CELLS = 2.0            # 20 м, как у игры (0,8 клетки 25 м): ступеньки леса в DSM
M_LAT = FD.EARTH_R_M * math.pi / 180.0


def tm_to_ll(e, n):
    from pyproj import Transformer
    t = Transformer.from_crs(PT_TM06, "EPSG:4326", always_xy=True)
    lon, lat = t.transform(e, n)
    return lat, lon


def frame():
    lat0, lon0 = tm_to_ll(*CENTER_TM)
    return lat0, lon0


def ll_to_xy(lat, lon, lat0, lon0):
    m_lon = M_LAT * math.cos(math.radians(lat0))
    return (lon - lon0) * m_lon, (lat - lat0) * M_LAT


def build(size_m=SIZE_M):
    lat0, lon0 = frame()
    SIZE_M = size_m
    # DSM: build_layer игры (узлы через 10 м, размер на 10 м меньше → узлы в центрах подклеток 10 м)
    size_km = (SIZE_M - FINE) / 1000.0
    layer = dict(id="perdigao", size_km=size_km, spacing_m=FINE, source="copernicus",
                 smooth_sigma_cells=SMOOTH_SIGMA_CELLS, quantize_per_m=32)
    h, info = FD.build_layer(lat0, lon0, layer)
    dsm = h[::-1].astype(np.float32)          # строка 0 — юг
    n = dsm.shape[0]
    xs = info["origin_x_m"] + np.arange(n) * FINE       # восток
    ys = -(info["origin_z_m"] + np.arange(n) * FINE)    # z — юг → y = −z, затем по возрастанию
    ys = ys[::-1]
    # доля леса (WorldCover класс 10 «деревья») в клетках 10 м: 3×3 подвыборки уровня 0
    wc = json.load(open(ROOT / "configs/world.json"))["surface"]["worldcover"]
    k = 3
    cnt = np.zeros((n, n), np.float32)
    shrub = np.zeros((n, n), np.float32)
    offs = (np.arange(k) + 0.5) / k - 0.5
    m_lon = M_LAT * math.cos(math.radians(lat0))
    X, Y = np.meshgrid(xs, ys)
    for dy in offs:
        for dx in offs:
            lat = lat0 + (Y + dy * FINE) / M_LAT
            lon = lon0 + (X + dx * FINE) / m_lon
            code = FL.sample_worldcover(lat, lon, 0, wc)
            cnt += (code == 10) | (code == 95)
            shrub += code == 20
    tree = cnt / (k * k)
    shrub /= k * k
    name = "terrain10.npz" if size_m == 6000.0 else f"terrain10_{int(size_m) // 1000}km.npz"
    np.savez_compressed(OUT / name, dsm=dsm, tree=tree.astype(np.float32), shrub=shrub.astype(np.float32),
                        x=xs, y=ys, lat0=lat0, lon0=lon0, center_tm=np.array(CENTER_TM), fine=FINE)
    return dsm, tree, xs, ys, lat0, lon0


def masts(lat0, lon0):
    from pyproj import Transformer
    t = Transformer.from_crs(PT_TM06, "EPSG:4326", always_xy=True)
    rows = []
    for r in csv.DictReader(open(TOWERS)):
        if r["name"] in ("?",) or float(r["terrain_elev_asl_m"]) <= 0:
            continue
        lon, lat = t.transform(float(r["sonic_easting_m"]), float(r["sonic_northing_m"]))
        x, y = ll_to_xy(lat, lon, lat0, lon0)
        rows.append(dict(name=r["name"], lat=lat, lon=lon, x=x, y=y, ground=float(r["terrain_elev_asl_m"])))
    return rows


def bil(a, xs, ys, x, y):
    fx = (x - xs[0]) / (xs[1] - xs[0])
    fy = (y - ys[0]) / (ys[1] - ys[0])
    i0, j0 = int(np.floor(fx)), int(np.floor(fy))
    if i0 < 0 or j0 < 0 or i0 + 1 >= len(xs) or j0 + 1 >= len(ys):
        return float("nan")
    a_, b_ = fx - i0, fy - j0
    return float((1 - b_) * ((1 - a_) * a[j0, i0] + a_ * a[j0, i0 + 1]) + b_ * ((1 - a_) * a[j0 + 1, i0] + a_ * a[j0 + 1, i0 + 1]))


def main():
    OUT.mkdir(exist_ok=True)
    dsm, tree, xs, ys, lat0, lon0 = build()
    ms = masts(lat0, lon0)
    lines = ["| мачта | x, м | y, м | высота мачты (towers_layout), м | DSM Copernicus, м | DSM − мачта, м | лес WorldCover (10 м, r=50 м) |",
             "|---|---|---|---|---|---|---|"]
    w = csv.writer(open(OUT / "masts.csv", "w"))
    w.writerow(["name", "lat", "lon", "x", "y", "ground_asl", "dsm", "dsm_minus_ground", "tree_frac_r50"])
    diffs = []
    for m in ms:
        d = bil(dsm, xs, ys, m["x"], m["y"])
        if math.isnan(d):
            continue
        ix, iy = np.meshgrid(xs, ys)
        near = (ix - m["x"]) ** 2 + (iy - m["y"]) ** 2 <= 50.0 ** 2
        tf = float(tree[near].mean())
        w.writerow([m["name"], f"{m['lat']:.6f}", f"{m['lon']:.6f}", f"{m['x']:.1f}", f"{m['y']:.1f}", m["ground"],
                    f"{d:.1f}", f"{d - m['ground']:.1f}", f"{tf:.2f}"])
        lines.append(f"| {m['name']} | {m['x']:.0f} | {m['y']:.0f} | {m['ground']:.1f} | {d:.1f} | {d - m['ground']:+.1f} | {tf:.2f} |")
        diffs.append(d - m["ground"])
    diffs = np.array(diffs)
    lines += ["", f"N = {len(diffs)}, DSM − мачта: среднее {diffs.mean():+.1f} м, медиана {np.median(diffs):+.1f} м, "
                  f"σ {diffs.std():.1f} м, 10–90 %: {np.percentile(diffs, 10):+.1f} … {np.percentile(diffs, 90):+.1f} м",
              f"Доля леса (WorldCover, класс 10) по области {SIZE_M / 1000:.0f} км: {tree.mean():.2f}; "
              f"по полосе между гряд ±1,5 км от центра: {tree[(abs(ix - 0) < 1500) & (abs(iy - 0) < 1500)].mean():.2f}"]
    (OUT / "terrain_check.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    print("lat0, lon0 =", lat0, lon0, " dsm range", dsm.min(), dsm.max())


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--size":          # контроль области (Б1): только рельеф, без мачт
        d, t, xs, ys, *_ = build(float(sys.argv[2]))
        print("size", sys.argv[2], "dsm", float(d.min()), float(d.max()), "лес", float(t.mean()))
    else:
        main()
