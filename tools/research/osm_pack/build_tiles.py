"""Нарезка минимального пакета крупными тайлами: квадрат 2×2 по 100×100 км вокруг точки.

    python -I build_tiles.py bbox <lat> <lon>                       # печать bbox lon/lat для osmium extract
    python -I build_tiles.py build <in.osm.pbf> <out_dir> <lat> <lon> [--only=ix,iy]
    python -I build_tiles.py analyze <out_dir> <res.json> <place>

Проекция — азимутальная равнопромежуточная от центра (aeqd, шар R=6371008.8); тайл (ix, iy),
ix, iy ∈ {-1, 0}: x ∈ [ix*100 км, (ix+1)*100 км], y аналогично (y — на север); координаты внутри
тайла — метры от его юго-западного угла, сетка 1 м, ДП 1 м. Состав и кодер — как detail из
build_min.py (ROAD_KEEP, озёра маской 10 м, посёлки, аэродромы, старты, обрывы, ж/д).
"""
from __future__ import annotations

import json
import math
import resource
import sys
import time
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
import osmium
import shapely
from pyproj import Transformer

sys.path.insert(0, str(Path(__file__).parent))
import build_min as bm  # noqa: E402
import osmpack as op  # noqa: E402

T = 100000.0
R = op.R_EARTH


def projs(lat, lon):
    crs = f"+proj=aeqd +lat_0={lat} +lon_0={lon} +R={R} +units=m +no_defs"
    return (Transformer.from_crs("EPSG:4326", crs, always_xy=True),
            Transformer.from_crs(crs, "EPSG:4326", always_xy=True))


def bbox(lat, lon, margin=0.02):
    _, inv = projs(lat, lon)
    xs = np.linspace(-T, T, 41)
    pts = [(x, y) for x in xs for y in (-T, T)] + [(x, y) for y in xs for x in (-T, T)]
    ll = np.array([inv.transform(x, y) for x, y in pts])
    return (ll[:, 0].min() - margin, ll[:, 1].min() - margin,
            ll[:, 0].max() + margin, ll[:, 1].max() + margin)


class TLevel(bm.Level):
    def __init__(self, fwd, only):
        super().__init__("tiles", T, 1.0, 1.0, False)
        self.fwd, self.only = fwd, only

    def want(self, ix, iy):
        return ix in (-1, 0) and iy in (-1, 0) and (self.only is None or self.only == (ix, iy))

    def point_ll(self, lon, lat, c):
        x, y = self.fwd.transform(lon, lat)
        ix, iy = math.floor(x / T), math.floor(y / T)
        if not self.want(ix, iy):
            return
        cell = self.cells[(ix, iy)]
        w = cell.w[c[0]]
        w.header(self.classes.get(c[0], f"{c[1]}:point"), *self.attrs(cell, c))
        w.pts([int(round(x - ix * T))], [int(round(y - iy * T))], with_n=False)
        self.parts[c[0]] += 1

    def emit_ll(self, g, c, gt):
        fwd = self.fwd
        gm = shapely.transform(g, lambda a: np.column_stack(fwd.transform(a[:, 0], a[:, 1])))
        minx, miny, maxx, maxy = gm.bounds
        if maxx < -T or minx > T or maxy < -T or miny > T:
            return
        cls_id = self.classes.get(c[0], f"{c[1]}:{gt}")
        for ix in (-1, 0):
            for iy in (-1, 0):
                if not self.want(ix, iy):
                    continue
                if maxx < ix * T or minx > (ix + 1) * T or maxy < iy * T or miny > (iy + 1) * T:
                    continue
                gg = shapely.clip_by_rect(gm, ix * T, iy * T, (ix + 1) * T, (iy + 1) * T)
                if gg.is_empty:
                    continue
                gg = shapely.transform(gg, lambda a: a - (ix * T, iy * T))
                cell = self.cells[(ix, iy)]
                if c[0] == "lakes":
                    cell.lakes.extend(p for p in shapely.get_parts(gg) if p.geom_type == "Polygon")
                gg = shapely.simplify(gg, self.tol, preserve_topology=(gt == "area"))
                self.write(cell, c, gt, cls_id, gg)


class TB(osmium.SimpleHandler):
    def __init__(self, lat, lon, only):
        super().__init__()
        fwd, _ = projs(lat, lon)
        self.lv = TLevel(fwd, only)
        self.wkb = osmium.geom.WKBFactory()
        self.fail = Counter()

    def node(self, n):
        if not n.tags:
            return
        c = bm.detail_spec(dict(n.tags), "point")
        if c and c[0] not in bm.NOT_POINT:
            self.lv.point_ll(n.location.lon, n.location.lat, c)

    def way(self, wy):
        c = bm.detail_spec(dict(wy.tags), "line")
        if not c:
            return
        try:
            g = shapely.from_wkb(self.wkb.create_linestring(wy))
        except Exception:
            self.fail["line"] += 1
            return
        self.lv.emit_ll(g, c, "line")

    def area(self, a):
        c = bm.detail_spec(dict(a.tags), "area")
        if not c:
            return
        try:
            g = shapely.from_wkb(self.wkb.create_multipolygon(a))
        except Exception:
            self.fail["area"] += 1
            return
        self.lv.emit_ll(g, c, "area")


def tname(ix, iy):
    return f"tile_{'S' if iy < 0 else 'N'}{'W' if ix < 0 else 'E'}"


def build(src, out, lat, lon, only):
    t0 = time.time()
    b = TB(lat, lon, only)
    b.apply_file(str(src), locations=True, idx="flex_mem")
    t_parse = time.time() - t0
    lv = b.lv
    out.mkdir(parents=True, exist_ok=True)
    t1 = time.time()
    for (ix, iy), cell in sorted(lv.cells.items()):
        streams = {s: bytes(w.buf) for s, w in cell.w.items()}
        streams["names"] = cell.names.encode() if cell.names.idx else b""
        nm = tname(ix, iy)
        (out / f"{nm}.bin").write_bytes(op.pack_cell(streams))
        if cell.lakes:
            w = h = int(T / bm.MASK_M)
            m, e = bm.rasterize(cell.lakes, w, h)
            (out / f"{nm}.mask").write_bytes(
                w.to_bytes(2, "little") + h.to_bytes(2, "little") + np.packbits(m, axis=1).tobytes())
    st = {"center": [lat, lon], "t_parse_s": round(t_parse, 1),
          "t_mask_write_s": round(time.time() - t1, 1), "only": only,
          "maxrss_MB": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024),
          "parts": {tname(*k): dict(Counter({s: w.count for s, w in c.w.items() if w.count}))
                    for k, c in lv.cells.items()},
          "geom_fail": dict(b.fail)}
    (out / "build_stats.json").write_text(json.dumps(st, ensure_ascii=False, indent=1))
    print(json.dumps(st, ensure_ascii=False))


def analyze(out, res, place):
    import analyze_min as am
    files = sorted(out.glob("tile_*.bin"))
    with ProcessPoolExecutor(max_workers=4) as ex:
        rows = dict(ex.map(am.one, [(str(f), 1) for f in files]))
    bs = json.loads((out / "build_stats.json").read_text())
    r = {"place": place, "center": bs["center"], "tile_km2": 10000, "build": bs, "tiles": {}}
    for nm, row in rows.items():
        tot = row["blob_nolakes_zstd"] + row.get("mask_best_zstd", 0)
        r["tiles"][nm] = {
            "total_zstd": tot, "bytes_per_km2": round(tot / 10000, 1),
            "total_br": row["blob_nolakes_br"] + row.get("mask_best_br", 0),
            "streams_zstd": {s: row.get(f"s_{s}_zstd", 0) for s in bm.STREAMS},
            "lake_mask_zstd": row.get("mask_best_zstd", 0), "lake_px": row.get("mask_px", 0),
            "lakes_vector_zstd": row.get("s_lakes_zstd", 0),
            "objects": bs["parts"].get(nm, {})}
    res.write_text(json.dumps(r, ensure_ascii=False, indent=1))
    for nm, t in r["tiles"].items():
        print(place, nm, t["total_zstd"], t["bytes_per_km2"], t["streams_zstd"], t["lake_mask_zstd"])


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "bbox":
        print(",".join(f"{v:.4f}" for v in bbox(float(sys.argv[2]), float(sys.argv[3]))))
    elif cmd == "build":
        only = None
        for a in sys.argv[6:]:
            if a.startswith("--only="):
                only = tuple(int(v) for v in a[7:].split(","))
        build(Path(sys.argv[2]), Path(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), only)
    elif cmd == "analyze":
        analyze(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
