"""Замер размера рельефа и покрова в компактном виде (ячейки 0,25°, как у векторного пакета).

    uv run --with numpy --with tifffile --with imagecodecs --with shapely --with brotli \
        --with zstandard --with pillow python terrain_cover.py region <имя> <граница.geojson> <out.json>
    ... python terrain_cover.py builtin <out.json>

region: ячейки 0,25°, пересекающие границу субъекта/страны.
  Рельеф — Copernicus GLO-30 в родной сетке (1" по широте; 1" по долготе южнее 50°, 1,5" — 50–60°,
  т. е. ~31x21..31 м), кеш ~/.cache/deltaplan_terrain/copernicus (dl_rasters.sh).
  Варианты: int с шагом 1 м и 0,1 м (от минимума ячейки, uint16), без предсказателя и с плоским
  предсказателем (a + b - c) + zigzag + разбиение на байтовые плоскости; brotli q11 / zstd 19;
  для сравнения — float32 brotli (как data/terrain сейчас). Дальний слой — средние по блокам
  3x3 (~90 м) и 7x7 (~210 м, порядок Terrarium z9), шаг 1 м, с предсказателем.
  Покров — ESA WorldCover 2021 v200, классы uint8: 10 м (родной), 25 м (ближайший сосед, шаг
  2,5 пикс), 25 м в 8 классах игры (configs/world.json); brotli q11 / zstd 19.
builtin: data/terrain/<4 локации> — текущие файлы против тех же высот в int16-виде.
"""
from __future__ import annotations

import json
import math
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import brotli
import numpy as np
import zstandard

CELL = 0.25
COP = Path.home() / ".cache" / "deltaplan_terrain" / "copernicus"
WC = Path("/home/greg/deltaplan_data/osm_pack/worldcover")
ROOT = Path(__file__).resolve().parents[3]
WC_GAME = {10: 1, 20: 4, 30: 2, 40: 3, 50: 7, 60: 5, 70: 8, 80: 6, 90: 2, 95: 1, 100: 2}


def br(b: bytes) -> int:
    return len(brotli.compress(b, quality=11, lgwin=24))


def zs(b: bytes) -> int:
    return len(zstandard.ZstdCompressor(level=19).compress(b))


def planar(q: np.ndarray) -> np.ndarray:
    r = q.copy()
    r[1:, 1:] = q[1:, 1:] - q[1:, :-1] - q[:-1, 1:] + q[:-1, :-1]
    r[0, 1:] = q[0, 1:] - q[0, :-1]
    r[1:, 0] = q[1:, 0] - q[:-1, 0]
    return r


def enc_height(h: np.ndarray, step: float, pred: bool) -> bytes:
    q = np.rint(h.astype(np.float64) / step).astype(np.int64)
    q -= q.min()
    if not pred:
        assert q.max() < 65536
        return q.astype("<u2").tobytes()
    r = planar(q)
    z = ((r << 1) ^ (r >> 63)).astype(np.int64)
    assert z.max() < 65536, z.max()
    u = z.astype(np.uint16)
    return (u & 0xFF).astype(np.uint8).tobytes() + (u >> 8).astype(np.uint8).tobytes()


def block_mean(a: np.ndarray, k: int) -> np.ndarray:
    h, w = (a.shape[0] // k) * k, (a.shape[1] // k) * k
    return a[:h, :w].reshape(h // k, k, w // k, k).mean(axis=(1, 3))


def job_dem(h: np.ndarray) -> dict:
    out = {"n": int(h.size)}
    for name, step, pred in (("q1", 1.0, False), ("q1p", 1.0, True), ("q01", 0.1, False),
                             ("q01p", 0.1, True)):
        b = enc_height(h, step, pred)
        out[f"{name}_raw"] = len(b)
        out[f"{name}_br"] = br(b)
        out[f"{name}_zstd"] = zs(b)
    out["f32_br"] = len(brotli.compress(h.astype("<f4").tobytes(), quality=11, lgwin=22))
    for k in (3, 7):
        m = block_mean(h, k)
        b = enc_height(m, 1.0, True)
        out[f"far{k}_n"] = int(m.size)
        out[f"far{k}_q1p_br"] = br(b)
        out[f"far{k}_q1p_zstd"] = zs(b)
    return out


def job_wc(c: np.ndarray) -> dict:
    out = {"n10": int(c.size)}
    b = c.tobytes()
    out["wc10_br"] = br(b)
    out["wc10_zstd"] = zs(b)
    idx = (np.arange(0, c.shape[0], 2.5) + 1.25).astype(int)
    idy = (np.arange(0, c.shape[1], 2.5) + 1.25).astype(int)
    c25 = c[np.ix_(idx, idy)]
    out["n25"] = int(c25.size)
    out["wc25_br"] = br(c25.tobytes())
    out["wc25_zstd"] = zs(c25.tobytes())
    lut = np.zeros(256, np.uint8)
    for k, v in WC_GAME.items():
        lut[k] = v
    g = lut[c25]
    out["game25_br"] = br(g.tobytes())
    out["game25_zstd"] = zs(g.tobytes())
    return out


def region_cells(geojson: Path):
    import shapely
    from shapely.geometry import shape
    g = shape(json.loads(geojson.read_text())["features"][0]["geometry"])
    minx, miny, maxx, maxy = g.bounds
    cells = []
    for ix in range(math.floor(minx / CELL), math.floor(maxx / CELL) + 1):
        for iy in range(math.floor(miny / CELL), math.floor(maxy / CELL) + 1):
            box = shapely.box(ix * CELL, iy * CELL, (ix + 1) * CELL, (iy + 1) * CELL)
            if g.intersects(box):
                cells.append((ix, iy))
    latc = (miny + maxy) / 2
    k = 111.195
    area = shapely.transform(g, lambda a: a * (k * math.cos(math.radians(latc)), k)).area
    return cells, area


def cell_area_km2(iy: int) -> float:
    lat = (iy + 0.5) * CELL
    return (CELL * 111.195) ** 2 * math.cos(math.radians(lat))


def region(name: str, geojson: Path, out_json: Path):
    import tifffile
    cells, area = region_cells(geojson)
    t0 = time.time()
    res = {"region": name, "area_km2": round(area), "cells": len(cells),
           "cells_area_km2": round(sum(cell_area_km2(iy) for _, iy in cells))}
    dem_jobs = {}
    wc_jobs = {}
    missing = []
    with ProcessPoolExecutor(max_workers=18) as ex:
        by_tile = {}
        for ix, iy in cells:
            by_tile.setdefault((math.floor(iy * CELL), math.floor(ix * CELL)), []).append((ix, iy))
        for (la, lo), cs in sorted(by_tile.items()):
            f = COP / f"Copernicus_DSM_COG_10_N{la:02d}_00_E{lo:03d}_00_DEM.tif"
            if not f.exists():
                missing.append(f.name)
                continue
            t = tifffile.imread(f).astype(np.float32)
            rows, cols = t.shape
            for ix, iy in cs:
                r0 = round((la + 1 - (iy + 1) * CELL) * rows)
                c0 = round((ix * CELL - lo) * cols)
                sub = t[r0:r0 + rows // 4, c0:c0 + cols // 4]
                dem_jobs[(ix, iy)] = ex.submit(job_dem, np.ascontiguousarray(sub))
        by_wc = {}
        for ix, iy in cells:
            la, lo = 3 * math.floor(iy * CELL / 3), 3 * math.floor(ix * CELL / 3)
            by_wc.setdefault((la, lo), []).append((ix, iy))
        for (la, lo), cs in sorted(by_wc.items()):
            f = WC / f"ESA_WorldCover_10m_2021_v200_N{la:02d}E{lo:03d}_Map.tif"
            if not f.exists():
                missing.append(f.name)
                continue
            t = tifffile.imread(f)
            n = t.shape[0] // 12  # пикселей на 0,25°
            for ix, iy in cs:
                r0 = round((la + 3 - (iy + 1) * CELL) / CELL) * n
                c0 = round((ix * CELL - lo) / CELL) * n
                wc_jobs[(ix, iy)] = ex.submit(job_wc, np.ascontiguousarray(t[r0:r0 + n, c0:c0 + n]))
            del t
        dem = {k: v.result() for k, v in dem_jobs.items()}
        wc = {k: v.result() for k, v in wc_jobs.items()}
    tot = {}
    for d in list(dem.values()) + list(wc.values()):
        for k, v in d.items():
            tot[k] = tot.get(k, 0) + v
    res.update({"missing": missing, "dem_cells": len(dem), "wc_cells": len(wc), "totals": tot,
                "t_s": round(time.time() - t0, 1),
                "per_cell": {f"{iy}_{ix}": {**dem.get((ix, iy), {}), **wc.get((ix, iy), {})}
                             for ix, iy in cells}})
    out_json.write_text(json.dumps(res, indent=1))
    print(json.dumps({k: v for k, v in res.items() if k != "per_cell"}, indent=1))


def builtin(out_json: Path):
    from PIL import Image
    res = {}
    for loc in ("altai", "ongudai", "askarovo", "aushkul"):
        d = ROOT / "data" / "terrain" / loc
        meta = json.loads((d / "meta.json").read_text())
        r = {"files": {p.name: p.stat().st_size for p in sorted(d.iterdir())
                       if not p.name.endswith(".import")}}
        r["files_total"] = sum(r["files"].values())
        for lay in meta["layers"]:
            h = np.frombuffer(brotli.decompress((d / lay["file"]).read_bytes()), "<f4")
            h = h.reshape(lay["height"], lay["width"])
            for name, step, pred in (("q1p", 1.0, True), ("q01p", 0.1, True), ("q1", 1.0, False)):
                b = enc_height(h, step, pred)
                r[f"{lay['id']}_{name}_br"] = br(b)
                r[f"{lay['id']}_{name}_zstd"] = zs(b)
            for suf in ("_surface.png", "_water.png", "_detail10.png"):
                p = d / f"{lay['id']}{suf}"
                if p.exists():
                    a = np.asarray(Image.open(p))
                    r[f"{lay['id']}{suf}_raw_br"] = br(np.ascontiguousarray(a).tobytes())
        osm = ROOT / "data" / "osm" / f"{loc}.json"
        r["osm_json"] = osm.stat().st_size
        r["osm_json_br"] = br(osm.read_bytes())
        res[loc] = r
        print(loc, json.dumps(r), flush=True)
    out_json.write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    if sys.argv[1] == "region":
        region(sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4]))
    else:
        builtin(Path(sys.argv[2]))
