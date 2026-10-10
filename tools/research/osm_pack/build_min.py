"""Минимальный пакет OSM: озёра (маска 10 м + вектор), посёлки, аэродромы, старты, обрывы, дороги, ж/д.
Один проход по отфильтрованному PBF строит ДВА уровня:
  detail — ячейка 0,25°, сетка 1 м, Дуглас–Пейкер 1 м;
  world  — ячейка 1°, сетка 10 м, ДП 20 м, только крупное (см. WORLD_* ниже).

    python -I build_min.py <filtered.osm.pbf> <out_dir>
Пишет <out_dir>/{detail,world}/cells/<ячейка>.bin (+ .mask у detail), classes.json,
build_stats.json.
"""
from __future__ import annotations

import json
import math
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import osmium
import shapely
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
import osmpack as op  # noqa: E402

STREAMS = ["roads_main", "roads_tp", "rail", "lakes", "places", "airfields", "flights", "cliffs",
           "names"]
# detail: дороги — белый список (решение 10.10: path/footway/cycleway/bridleway/steps/pedestrian и
# мусорные proposed/planned/construction/abandoned/no/... не берём; track оставлен).
ROAD_KEEP = ["motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
             "residential", "living_street", "service", "road", "track",
             "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link"]
HIGHWAY_TP = {"track"}                         # отдельный поток для отчёта
import os  # noqa: E402
if os.environ.get("DP_ROADCLASS"):             # отладочный режим: поток на каждый класс дорог
    STREAMS[-1:-1] = ["r_" + c for c in ROAD_KEEP]
op.set_streams(STREAMS)
RIVER_WATER = {"river", "canal", "stream", "ditch", "drain", "riverbank", "stream_pool"}
WORLD_ROADS = {"motorway", "trunk", "primary", "secondary"}
WORLD_PLACES = {"city", "town", "village"}
WORLD_LAKE_KM2 = 1.0
MASK_M = 10.0
AERO = ("aerodrome", "airstrip", "helipad")
NOT_POINT = ("roads_main", "roads_tp", "rail", "lakes", "cliffs")  # r_* не точки


def num(v):
    if v is None:
        return None
    try:
        s = str(v).split(";")[0].replace(",", ".").strip().lower()
        for suf in ("m", "meters", "метров", "м"):
            if s.endswith(suf):
                s = s[: -len(suf)].strip()
        x = float(s)
        return x if math.isfinite(x) else None
    except ValueError:
        return None


def yes(v):
    return v is not None and v not in ("no", "false", "0")


def is_lake(t):
    if t.get("natural") == "water":
        return t.get("water") not in RIVER_WATER
    if t.get("landuse") in ("reservoir", "basin"):
        return True
    return "water" in t and t.get("water") not in RIVER_WATER and t.get("natural") != "wetland"


def ff_class(t):
    if t.get("sport") == "free_flying" or any(k.startswith("free_flying:") for k in t):
        return t.get("free_flying:site") or ("takeoff" if "free_flying:takeoff" in t else "site")
    return None


def spec(stream, cls, width=None, name=None, tun=False, br=False):
    return (stream, cls, width, None, name, tun, br)


def detail_spec(t, gt):
    if gt == "line":
        hw = t.get("highway")
        if hw in ROAD_KEEP and t.get("area") != "yes":
            st = "r_" + hw if os.environ.get("DP_ROADCLASS") else (
                "roads_tp" if hw in HIGHWAY_TP else "roads_main")
            return spec(st, hw, num(t.get("width")),
                        None, yes(t.get("tunnel")), yes(t.get("bridge")))
        if t.get("railway") in ("rail", "narrow_gauge"):
            return spec("rail", t["railway"], None, None, yes(t.get("tunnel")), yes(t.get("bridge")))
        if t.get("natural") == "cliff":
            return ("cliffs", "cliff", None, num(t.get("height")), None, False, False)
        if t.get("aeroway") == "runway" and t.get("area") != "yes":
            return spec("airfields", "runway", num(t.get("width")))
        return None
    if gt == "area" and is_lake(t):
        return spec("lakes", t.get("water") or t.get("landuse") or "water")
    if "place" in t:
        return spec("places", t["place"], None, t.get("name"))
    ae = t.get("aeroway")
    if ae in AERO or (ae == "runway" and t.get("area") == "yes"):
        return spec("airfields", ae, None, t.get("name"))
    ff = ff_class(t)
    if ff:
        return spec("flights", ff, None, t.get("name"))
    return None


def world_spec(t, gt):
    if gt == "line":
        hw = t.get("highway")
        if hw in WORLD_ROADS and t.get("area") != "yes":
            return spec("roads_main", hw, None, None, yes(t.get("tunnel")), yes(t.get("bridge")))
        if t.get("railway") == "rail":
            return spec("rail", "rail", None, None, yes(t.get("tunnel")), yes(t.get("bridge")))
        return None
    if gt == "area" and is_lake(t):
        return spec("lakes", "lake")
    if t.get("place") in WORLD_PLACES:
        return spec("places", t["place"], None, t.get("name"))
    if t.get("aeroway") in AERO:
        return spec("airfields", t["aeroway"], None, t.get("name"))
    ff = ff_class(t)
    if ff:
        return spec("flights", ff, None, t.get("name"))
    return None


class Cell:
    __slots__ = ("w", "names", "lakes")

    def __init__(self):
        self.w = {s: op.StreamWriter() for s in STREAMS if s != "names"}
        self.names = op.NameTable()
        self.lakes = []        # полигоны озёр в метрах ячейки (для маски), только detail


class Level:
    def __init__(self, name, deg, grid, tol, world):
        self.name, self.deg, self.grid, self.tol, self.world = name, deg, grid, tol, world
        self.cells = defaultdict(Cell)
        self.classes = op.ClassTable()
        self.parts = Counter()
        self.objs = Counter()
        self.origins = {}

    def origin(self, ix, iy):
        o = self.origins.get((ix, iy))
        if o is None:
            lon0, lat0 = ix * self.deg, iy * self.deg
            kx = op.M_PER_DEG * math.cos(math.radians(lat0 + self.deg / 2))
            o = self.origins[(ix, iy)] = (lon0, lat0, kx, op.M_PER_DEG)
        return o

    def quant(self, coords):
        q = np.rint(coords / self.grid).astype(np.int64)
        if len(q) > 1:
            keep = np.ones(len(q), bool)
            keep[1:] = np.any(q[1:] != q[:-1], axis=1)
            q = q[keep]
        return q

    def attrs(self, cell, c):
        s, cls, width, height, name, tun, br = c
        wdm = None if width is None or width <= 0 else min(int(round(width * 10)), 100000)
        h = None if height is None else int(round(height))
        return wdm, h, (cell.names.get(name) if name else None), tun, br

    def point(self, lon, lat, c):
        ix, iy = math.floor(lon / self.deg), math.floor(lat / self.deg)
        lon0, lat0, kx, ky = self.origin(ix, iy)
        cell = self.cells[(ix, iy)]
        w = cell.w[c[0]]
        w.header(self.classes.get(c[0], f"{c[1]}:point"), *self.attrs(cell, c))
        w.pts([int(round((lon - lon0) * kx / self.grid))],
              [int(round((lat - lat0) * ky / self.grid))], with_n=False)
        self.parts[c[0]] += 1

    def emit(self, g, c, gt):
        minx, miny, maxx, maxy = g.bounds
        d = self.deg
        ix0, ix1 = math.floor(minx / d), math.floor(maxx / d)
        iy0, iy1 = math.floor(miny / d), math.floor(maxy / d)
        cls_id = self.classes.get(c[0], f"{c[1]}:{gt}")
        for ix in range(ix0, ix1 + 1):
            for iy in range(iy0, iy1 + 1):
                gg = g
                if ix0 != ix1 or iy0 != iy1:
                    gg = shapely.clip_by_rect(g, ix * d, iy * d, (ix + 1) * d, (iy + 1) * d)
                    if gg.is_empty:
                        continue
                lon0, lat0, kx, ky = self.origin(ix, iy)
                gg = shapely.transform(gg, lambda a: (a - (lon0, lat0)) * (kx, ky))
                cell = self.cells[(ix, iy)]
                if c[0] == "lakes" and not self.world:
                    cell.lakes.extend(p for p in shapely.get_parts(gg) if p.geom_type == "Polygon")
                if self.tol > 0:
                    gg = shapely.simplify(gg, self.tol, preserve_topology=(gt == "area"))
                self.write(cell, c, gt, cls_id, gg)

    def write(self, cell, c, gt, cls_id, gg):
        w = cell.w[c[0]]
        for part in shapely.get_parts(gg):
            if gt == "line":
                if part.geom_type != "LineString":
                    continue
                q = self.quant(shapely.get_coordinates(part))
                if len(q) < 2:
                    continue
                w.header(cls_id, *self.attrs(cell, c))
                w.pts(q[:, 0].tolist(), q[:, 1].tolist())
            else:
                if part.geom_type != "Polygon":
                    continue
                rings = []
                for k, ring in enumerate([part.exterior, *part.interiors]):
                    q = self.quant(shapely.get_coordinates(ring))
                    if len(q) > 1 and (q[0] == q[-1]).all():
                        q = q[:-1]
                    if len(q) < 3:
                        if k == 0:
                            break
                        continue
                    rings.append((q[:, 0].tolist(), q[:, 1].tolist()))
                if not rings:
                    continue
                w.header(cls_id, *self.attrs(cell, c))
                w.rings(rings)
            self.parts[c[0]] += 1


class Builder(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.det = Level("detail", 0.25, 1.0, 1.0, False)
        self.wor = Level("world", 1.0, 10.0, 20.0, True)
        self.wkb = osmium.geom.WKBFactory()
        self.fail = Counter()

    def node(self, n):
        if not n.tags:
            return
        t = dict(n.tags)
        lon, lat = n.location.lon, n.location.lat
        for lv, fn in ((self.det, detail_spec), (self.wor, world_spec)):
            c = fn(t, "point")
            if c and c[0] not in NOT_POINT:
                lv.objs[f"{c[0]}/{c[1]}:point"] += 1
                lv.point(lon, lat, c)

    def way(self, wy):
        t = dict(wy.tags)
        specs = [(lv, fn(t, "line")) for lv, fn in ((self.det, detail_spec),
                                                     (self.wor, world_spec))]
        if not any(c for _, c in specs):
            return
        try:
            g = shapely.from_wkb(self.wkb.create_linestring(wy))
        except Exception:
            self.fail["line"] += 1
            return
        for lv, c in specs:
            if c:
                lv.objs[f"{c[0]}/{c[1]}:line"] += 1
                lv.emit(g, c, "line")

    def area(self, a):
        t = dict(a.tags)
        cd, cw = detail_spec(t, "area"), world_spec(t, "area")
        if not cd and not cw:
            return
        try:
            g = shapely.from_wkb(self.wkb.create_multipolygon(a))
        except Exception:
            self.fail["area"] += 1
            return
        if cd:
            self.det.objs[f"{cd[0]}/{cd[1]}:area"] += 1
            self.det.emit(g, cd, "area")
        if cw:
            if cw[0] == "lakes":
                km2 = g.area * (111.195 ** 2) * math.cos(math.radians(g.centroid.y))
                if km2 >= WORLD_LAKE_KM2:
                    self.wor.objs["lakes/lake:area"] += 1
                    self.wor.emit(g, cw, "area")
            else:   # площадной посёлок/аэродром/старт -> точка
                p = shapely.point_on_surface(g)
                self.wor.objs[f"{cw[0]}/{cw[1]}:point(from area)"] += 1
                self.wor.point(p.x, p.y, cw)


def rasterize(cell_lakes, w, h):
    """Маска озёр ячейки: bool[h, w], строка 0 — юг; 10 м на пиксель, центр пикселя."""
    m = np.zeros((h, w), bool)
    empty = 0
    for p in cell_lakes:
        x0, y0, x1, y1 = p.bounds
        bx0, by0 = max(int(x0 / MASK_M) - 1, 0), max(int(y0 / MASK_M) - 1, 0)
        bx1, by1 = min(int(x1 / MASK_M) + 2, w), min(int(y1 / MASK_M) + 2, h)
        if bx1 <= bx0 or by1 <= by0:
            continue
        im = Image.new("1", (bx1 - bx0, by1 - by0), 0)
        dr = ImageDraw.Draw(im)

        def tr(ring):
            return [((x / MASK_M - 0.5) - bx0, (y / MASK_M - 0.5) - by0) for x, y in ring.coords]
        dr.polygon(tr(p.exterior), fill=1)
        for r in p.interiors:
            dr.polygon(tr(r), fill=0)
        a = np.array(im, bool)
        if not a.any():
            empty += 1
        m[by0:by1, bx0:bx1] |= a
    return m, empty


def main():
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    t0 = time.time()
    b = Builder()
    b.apply_file(str(src), locations=True, idx="flex_mem")
    t_parse = time.time() - t0
    print(f"разбор+геометрия {t_parse:.1f} с; ячеек detail {len(b.det.cells)}, world "
          f"{len(b.wor.cells)}", flush=True)
    stats = {"t_parse_s": round(t_parse, 1), "geom_fail": dict(b.fail)}
    t1 = time.time()
    for lv in (b.det, b.wor):
        d = out / lv.name / "cells"
        d.mkdir(parents=True, exist_ok=True)
        empty_lakes = 0
        for (ix, iy), cell in sorted(lv.cells.items()):
            streams = {s: bytes(w.buf) for s, w in cell.w.items()}
            streams["names"] = cell.names.encode() if cell.names.idx else b""
            nm = op.cell_name(ix, iy)
            (d / f"{nm}.bin").write_bytes(op.pack_cell(streams))
            if cell.lakes:
                lon0, lat0, kx, ky = lv.origin(ix, iy)
                w, h = math.ceil(lv.deg * kx / MASK_M), math.ceil(lv.deg * ky / MASK_M)
                m, e = rasterize(cell.lakes, w, h)
                empty_lakes += e
                (d / f"{nm}.mask").write_bytes(
                    w.to_bytes(2, "little") + h.to_bytes(2, "little")
                    + np.packbits(m, axis=1).tobytes())
        (out / lv.name / "classes.json").write_text(
            json.dumps(lv.classes.names, ensure_ascii=False, indent=1))
        stats[lv.name] = {"deg": lv.deg, "grid_m": lv.grid, "tol_m": lv.tol,
                          "cells": len(lv.cells), "parts": dict(lv.parts),
                          "osm_objects": dict(sorted(lv.objs.items())),
                          "lake_parts_empty_in_mask": empty_lakes}
    stats["t_write_mask_s"] = round(time.time() - t1, 1)
    (out / "build_stats.json").write_text(json.dumps(stats, ensure_ascii=False, indent=1))
    print(json.dumps(stats, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
