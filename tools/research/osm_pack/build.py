"""Сборка векторного пакета из отфильтрованного .osm.pbf (см. filter.txt, README.md).

    uv run --with osmium --with shapely --with numpy --with brotli --with zstandard \
        python build.py <filtered.osm.pbf> <out_dir> [--grid=1.0] [--tol=1.0]

Пишет <out_dir>/cells/<ячейка>.bin (сырой блоб), classes.json, stats.json (размеры по потокам и
группам, сырые/brotli/zstd, счётчики объектов по классам, время).
"""
from __future__ import annotations

import json
import math
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import brotli
import numpy as np
import osmium
import shapely
import zstandard

sys.path.insert(0, str(Path(__file__).parent))
import osmpack as op  # noqa: E402


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


def is_yes(v):
    return v is not None and v not in ("no", "false", "0")


# --- классификация: -> (поток, класс, ширина_м, высота_м, имя, тоннель, мост) или None ---------
def classify_line(t):
    hw = t.get("highway")
    if hw and t.get("area") != "yes":
        s = "roads_tp" if hw in op.HIGHWAY_TP else "roads_main"
        return (s, hw, num(t.get("width")), None, None, is_yes(t.get("tunnel")),
                is_yes(t.get("bridge")))
    rw = t.get("railway")
    if rw in ("rail", "narrow_gauge"):
        return ("rail", rw, None, None, None, is_yes(t.get("tunnel")), is_yes(t.get("bridge")))
    ww = t.get("waterway")
    if ww in ("river", "stream", "canal", "ditch", "drain"):
        return ("water_lines", ww, num(t.get("width")), None, None,
                is_yes(t.get("tunnel")), is_yes(t.get("bridge")))
    if t.get("natural") == "cliff":
        return ("cliffs", "cliff", None, num(t.get("height")), None, False, False)
    pw = t.get("power")
    if pw in ("line", "minor_line"):
        return ("pilot", "power_" + pw, None, None, None, False, False)
    aw = t.get("aerialway")
    if aw and aw not in ("pylon", "station"):
        return ("pilot", "aerialway_" + aw, None, None, None, False, False)
    if t.get("aeroway") == "runway" and t.get("area") != "yes":
        return ("pilot", "aeroway_runway", num(t.get("width")), None, None, False, False)
    return None


def classify_area(t):
    nat = t.get("natural")
    lu = t.get("landuse")
    if nat == "water" or ("water" in t and nat != "wetland") or lu in ("reservoir", "basin"):
        return ("water_areas", t.get("water") or lu or "water", None, None, None, False, False)
    if nat in ("wetland", "glacier", "wood", "scrub", "heath", "grassland", "bare_rock", "scree",
               "shingle", "sand"):
        return ("landcover", nat, None, None, None, False, False)
    if lu in op.LANDCOVER:
        return ("landcover", lu, None, None, None, False, False)
    if "place" in t:
        return ("places", t.get("place"), None, None, t.get("name"), False, False)
    return classify_pilot(t)


def classify_pilot(t):
    """Объекты для пилота (точки/полигоны): аэродромы, старты/посадки, ветряки, мачты, вершины."""
    ae = t.get("aeroway")
    if ae in ("aerodrome", "airstrip", "helipad") or (ae == "runway" and t.get("area") == "yes"):
        return ("pilot", "aeroway_" + ae, None, num(t.get("ele")), t.get("name"), False, False)
    ff = t.get("sport") == "free_flying" or any(k.startswith("free_flying:") for k in t)
    if ff:
        site = t.get("free_flying:site") or ("takeoff" if "free_flying:takeoff" in t else "site")
        return ("pilot", "free_flying_" + site, None, num(t.get("ele")), t.get("name"), False,
                False)
    if t.get("power") == "generator" and t.get("generator:source") == "wind":
        return ("pilot", "wind_turbine", None, num(t.get("height")), None, False, False)
    mm = t.get("man_made")
    if mm in ("mast", "tower", "communications_tower", "chimney"):
        return ("pilot", "man_made_" + mm, None, num(t.get("height")), None, False, False)
    return None


def classify_node(t):
    if "place" in t:
        return ("places", t.get("place"), None, None, t.get("name"), False, False)
    pw = t.get("power")
    if pw in ("tower", "pole"):
        return ("pilot", "power_" + pw, None, num(t.get("height")), None, False, False)
    if t.get("aerialway") == "pylon":
        return ("pilot", "aerialway_pylon", None, num(t.get("height")), None, False, False)
    nat = t.get("natural")
    if nat in ("peak", "saddle") and t.get("name"):
        return ("pilot", "natural_" + nat, None, num(t.get("ele")), t.get("name"), False, False)
    return classify_pilot(t)


class Cell:
    __slots__ = ("w", "names")

    def __init__(self):
        self.w = {s: op.StreamWriter() for s in op.STREAMS if s != "names"}
        self.names = op.NameTable()


class Builder(osmium.SimpleHandler):
    def __init__(self, grid, tol):
        super().__init__()
        self.grid = grid
        self.tol = tol
        self.cells: dict[tuple, Cell] = defaultdict(Cell)
        self.classes = op.ClassTable()
        self.count = Counter()  # объекты OSM по классу
        self.ele_count = Counter()
        self.parts = Counter()  # записанные объекты (после нарезки) по потоку
        self.fail = Counter()
        self.wkb = osmium.geom.WKBFactory()
        self.origins = {}

    def origin(self, ix, iy):
        o = self.origins.get((ix, iy))
        if o is None:
            o = self.origins[(ix, iy)] = op.cell_origin(ix, iy)
        return o

    # --- запись ---------------------------------------------------------------------------
    def attrs(self, cell, c):
        s, cls, width, height, name, tun, br = c
        wdm = None if width is None or width <= 0 else min(int(round(width * 10)), 100000)
        h = None if height is None else int(round(height))
        ni = cell.names.get(name) if name else None
        return wdm, h, ni, tun, br

    def quant(self, coords):
        q = np.rint(coords / self.grid).astype(np.int64)
        if len(q) > 1:
            keep = np.ones(len(q), bool)
            keep[1:] = np.any(q[1:] != q[:-1], axis=1)
            q = q[keep]
        return q

    def emit(self, g, c, gt):
        """g — геометрия в градусах; нарезать по ячейкам, спроецировать, упростить, записать."""
        minx, miny, maxx, maxy = g.bounds
        ix0, ix1 = math.floor(minx / op.CELL_DEG), math.floor(maxx / op.CELL_DEG)
        iy0, iy1 = math.floor(miny / op.CELL_DEG), math.floor(maxy / op.CELL_DEG)
        cls_id = self.classes.get(c[0], f"{c[1]}:{gt}")
        for ix in range(ix0, ix1 + 1):
            for iy in range(iy0, iy1 + 1):
                gg = g
                if ix0 != ix1 or iy0 != iy1:
                    d = op.CELL_DEG
                    gg = shapely.clip_by_rect(g, ix * d, iy * d, (ix + 1) * d, (iy + 1) * d)
                    if gg.is_empty:
                        continue
                lon0, lat0, kx, ky = self.origin(ix, iy)
                gg = shapely.transform(gg, lambda a: (a - (lon0, lat0)) * (kx, ky))
                if self.tol > 0:
                    gg = shapely.simplify(gg, self.tol, preserve_topology=(gt == "area"))
                self.write(self.cells[(ix, iy)], c, gt, cls_id, gg)

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

    def note(self, c, gt):
        self.count[f"{c[0]}/{c[1]}:{gt}"] += 1
        if c[3] is not None and c[0] == "pilot":
            self.ele_count[f"{c[1]}:{gt}"] += 1

    # --- обработчики osmium -----------------------------------------------------------------
    def node(self, n):
        if not n.tags:
            return
        t = dict(n.tags)
        c = classify_node(t)
        if c is None:
            return
        self.note(c, "point")
        lon, lat = n.location.lon, n.location.lat
        ix, iy = math.floor(lon / op.CELL_DEG), math.floor(lat / op.CELL_DEG)
        lon0, lat0, kx, ky = self.origin(ix, iy)
        cell = self.cells[(ix, iy)]
        cls_id = self.classes.get(c[0], f"{c[1]}:point")
        w = cell.w[c[0]]
        w.header(cls_id, *self.attrs(cell, c))
        w.pts([int(round((lon - lon0) * kx / self.grid))],
              [int(round((lat - lat0) * ky / self.grid))], with_n=False)
        self.parts[c[0]] += 1

    def way(self, wy):
        t = dict(wy.tags)
        c = classify_line(t)
        if c is None:
            return
        self.note(c, "line")
        try:
            g = shapely.from_wkb(self.wkb.create_linestring(wy), )
        except Exception:
            self.fail["line"] += 1
            return
        self.emit(g, c, "line")

    def area(self, a):
        t = dict(a.tags)
        c = classify_area(t)
        if c is None:
            return
        self.note(c, "area")
        try:
            g = shapely.from_wkb(self.wkb.create_multipolygon(a))
        except Exception:
            self.fail["area"] += 1
            return
        self.emit(g, c, "area")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--"))
    src, out = Path(args[0]), Path(args[1])
    grid = float(opts.get("grid", 1.0))
    tol = float(opts.get("tol", 1.0))
    (out / "cells").mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    b = Builder(grid, tol)
    b.apply_file(str(src), locations=True, idx="flex_mem")
    t_parse = time.time() - t0
    print(f"разбор+геометрия {t_parse:.1f} с, ячеек {len(b.cells)}", flush=True)

    zc = zstandard.ZstdCompressor(level=19)
    stats = {"grid_m": grid, "tol_m": tol, "cell_deg": op.CELL_DEG, "src": str(src),
             "t_parse_s": round(t_parse, 1)}
    per_stream = defaultdict(lambda: Counter())
    tot = Counter()
    cell_rows = []
    t1 = time.time()
    for (ix, iy), cell in sorted(b.cells.items()):
        streams = {s: bytes(w.buf) for s, w in cell.w.items()}
        streams["names"] = cell.names.encode() if cell.names.idx else b""
        blob = op.pack_cell(streams)
        (out / "cells" / f"{op.cell_name(ix, iy)}.bin").write_bytes(blob)
        row = {"cell": op.cell_name(ix, iy)}
        for var, skip in (("all", ()), ("no_tp", ("roads_tp",))):
            bb = blob if var == "all" else op.pack_cell(streams, skip)
            br = brotli.compress(bb, quality=11, lgwin=24)
            zs = zc.compress(bb)
            tot[f"{var}_raw"] += len(bb)
            tot[f"{var}_br"] += len(br)
            tot[f"{var}_zstd"] += len(zs)
            row[f"{var}_raw"] = len(bb)
            row[f"{var}_br"] = len(br)
        cell_rows.append(row)
        for s, v in streams.items():
            if not v:
                continue
            per_stream[s]["raw"] += len(v)
            per_stream[s]["br"] += len(brotli.compress(v, quality=11, lgwin=24))
            per_stream[s]["zstd"] += len(zc.compress(v))
    t_comp = time.time() - t1
    print(f"сжатие {t_comp:.1f} с", flush=True)
    stats["t_compress_s"] = round(t_comp, 1)
    stats["cells"] = len(b.cells)
    stats["totals"] = dict(tot)
    stats["streams"] = {s: dict(v) for s, v in per_stream.items()}
    stats["groups"] = {g: {k: sum(per_stream[s][k] for s in ss) for k in ("raw", "br", "zstd")}
                       for g, ss in op.GROUPS.items()}
    stats["parts"] = dict(b.parts)
    stats["osm_objects"] = dict(sorted(b.count.items()))
    stats["pilot_with_height_or_ele"] = dict(sorted(b.ele_count.items()))
    stats["geom_fail"] = dict(b.fail)
    stats["cell_rows"] = cell_rows
    (out / "classes.json").write_text(json.dumps(b.classes.names, ensure_ascii=False, indent=1))
    (out / "stats.json").write_text(json.dumps(stats, ensure_ascii=False, indent=1))
    print(json.dumps({k: stats[k] for k in ("totals", "groups")}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
