"""Поток «объекты для пилота» на той же мировой сетке 20 км (docs/plan/osm_vector_pack.md §9).

    python -I build_pilot20.py <in.osm.pbf> <res.json> [--want=j,i;...] [--poly=file.poly]

Подпотоки (zstd 19 каждый отдельно, дельты zigzag-varint, сетка 1 м, ДП 1 м, как в build_tiles20):
  powerline  way power=line|minor_line (линия; флаг minor)
  tower      node power=tower (точка)
  aerialway  way aerialway=* кроме pylon/station/zip_line? (линия; класс), без имён
  aeroway    aerodrome|airstrip|helipad: контур (area) или точка; runway — линия
  vertical   node man_made=mast|tower|chimney и power=generator + generator:source=wind;
             точка + высота (м) + класс
  peak/pass  natural=peak, saddle|mountain_pass=yes: точка + ele; names — имена отдельно
  river|canal  waterway=river, canal (линии, раздельно); river_named — подмножество рек с именем; comm — подмножество vertical
  rail       way railway=rail|narrow_gauge (линия)
"""
from __future__ import annotations

import json
import math
import resource
import subprocess
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import osmium
import shapely
import zstandard

sys.path.insert(0, str(Path(__file__).parent))
from build_tiles20 import Band, local, num, read_poly, tile_of, tiles_in_bbox, DLAT, enc_pts  # noqa: E402
from osmpack import put_varint  # noqa: E402

ZC = zstandard.ZstdCompressor(level=19)
SUBS = ("powerline", "tower", "aerialway", "aeroway", "vertical", "rail", "peak", "pass", "river", "canal", "river_named",
        "comm")   # river_named, comm — подмножества, в сумму не входят   # comm — подмножество vertical (отдельно для цены), в сумму не входит
FILTER = ["w/power=line,minor_line", "n/power=tower,generator", "w/aerialway", "nwr/aeroway=aerodrome,airstrip,helipad,runway",
          "w/railway=rail,narrow_gauge", "n/man_made=mast,tower,chimney", "n/natural=peak,saddle", "n/mountain_pass=yes",
          "w/waterway=river,canal"]


class P:
    def __init__(self, want):
        self.want = want
        self.items = defaultdict(lambda: defaultdict(list))   # tile -> sub -> [(cls, flags, h, arrays)]
        self.cls = {}
        self.n = Counter()
        self.names = defaultdict(list)

    def c(self, s):
        return self.cls.setdefault(s, len(self.cls))

    def ok(self, k):
        return self.want is None or k in self.want

    def line(self, g, sub, cls, fl=0):
        x0, y0, x1, y1 = g.bounds
        ks = list(tiles_in_bbox(x0, y0, x1, y1))
        for key in ks:
            if not self.ok(key):
                continue
            bd = Band.get(key[0])
            lo = bd.lon0(key[1])
            gg = g if len(ks) == 1 else shapely.clip_by_rect(g, lo, bd.lat0, lo + bd.dlon, bd.lat0 + DLAT)
            if gg.is_empty:
                continue
            gg = shapely.simplify(local(gg, key), 1.0)
            for p in shapely.get_parts(gg):
                if p.geom_type != "LineString":
                    continue
                a = np.rint(np.asarray(p.coords)).astype(np.int64)
                a = a[np.concatenate([[True], np.any(np.diff(a, axis=0) != 0, axis=1)])]
                if len(a) >= 2:
                    self.items[key][sub].append((self.c(cls), fl, 0, a))
                    self.n[sub] += 1

    def point(self, lon, lat, sub, cls, h=0, name=None):
        key = tile_of(lon, lat)
        if not self.ok(key):
            return
        bd = Band.get(key[0])
        a = np.array([[round((lon - bd.lon0(key[1])) * bd.kx), round((lat - bd.lat0) * bd.ky)]], dtype=np.int64)
        self.items[key][sub].append((self.c(cls), 0, max(0, int(round(h))), a))
        self.n[sub] += 1
        if name:
            self.names[key].append(name)


class H(osmium.SimpleHandler):
    def __init__(self, p):
        super().__init__()
        self.p = p
        self.wkb = osmium.geom.WKBFactory()

    def node(self, n):
        t = n.tags
        if not t:
            return
        p = self.p
        if t.get("power") == "tower":
            p.point(n.location.lon, n.location.lat, "tower", "tower")
        elif t.get("power") == "generator" and t.get("generator:source") == "wind":
            p.point(n.location.lon, n.location.lat, "vertical", "wind", num(t.get("height")) or 0)
        elif t.get("natural") == "peak":
            p.point(n.location.lon, n.location.lat, "peak", "peak", num(t.get("ele")) or 0, t.get("name"))
        elif t.get("natural") == "saddle" or t.get("mountain_pass") == "yes":
            p.point(n.location.lon, n.location.lat, "pass", "pass", num(t.get("ele")) or 0, t.get("name"))
        elif t.get("man_made") in ("mast", "tower", "chimney"):
            hh = num(t.get("height")) or 0
            p.point(n.location.lon, n.location.lat, "vertical", t["man_made"], hh)
            if t["man_made"] in ("mast", "tower") and t.get("tower:type") == "communication":
                p.point(n.location.lon, n.location.lat, "comm", "comm", hh)
        elif t.get("aeroway") in ("aerodrome", "airstrip", "helipad"):
            p.point(n.location.lon, n.location.lat, "aeroway", t["aeroway"])

    def way(self, w):
        t = w.tags
        p = self.p
        k = None
        if t.get("power") in ("line", "minor_line"):
            k = ("powerline", t["power"], 1 if t["power"] == "minor_line" else 0)
        elif t.get("aerialway") and t["aerialway"] not in ("pylon", "station"):
            k = ("aerialway", t["aerialway"], 0)
        elif t.get("aeroway") == "runway":
            k = ("aeroway", "runway", 0)
        elif t.get("waterway") in ("river", "canal"):
            k = (t["waterway"], t["waterway"], 0)
        elif t.get("railway") in ("rail", "narrow_gauge"):
            k = ("rail", t["railway"], 0)
        if not k:
            return
        try:
            g = shapely.from_wkb(self.wkb.create_linestring(w))
        except Exception:
            return
        p.line(g, k[0], k[1], k[2])
        if k[0] == "river" and t.get("name"):
            p.line(g, "river_named", "river", 0)

    def area(self, a):
        t = a.tags
        if t.get("aeroway") not in ("aerodrome", "airstrip", "helipad"):
            return
        try:
            g = shapely.from_wkb(self.wkb.create_multipolygon(a))
        except Exception:
            return
        for pg in shapely.get_parts(g):
            if pg.geom_type != "Polygon":
                continue
            c = pg.centroid
            key = tile_of(c.x, c.y)
            if not self.p.ok(key):
                continue
            ps = shapely.simplify(local(pg, key), 1.0)
            if ps.geom_type != "Polygon" or ps.is_empty:
                continue
            ring = np.rint(np.asarray(ps.exterior.coords)[:-1]).astype(np.int64)
            if len(ring) >= 3:
                self.p.items[key]["aeroway"].append((self.p.c(t["aeroway"] + ":area"), 0, 0, ring))
                self.p.n["aeroway"] += 1


def encode(items):
    buf = bytearray()
    lx = ly = 0
    for c, fl, h, a in items:
        put_varint(buf, c)
        buf.append(fl)
        put_varint(buf, h)
        put_varint(buf, len(a))
        lx, ly = enc_pts(buf, a, lx, ly)
    return bytes(buf)


def main():
    src, res = sys.argv[1], Path(sys.argv[2])
    want, poly = None, None
    for a in sys.argv[3:]:
        if a.startswith("--want="):
            want = {tuple(int(v) for v in t.split(",")) for t in a[7:].split(";")}
        if a.startswith("--poly="):
            poly = a[7:]
    f = Path(str(res) + ".pilot.pbf")
    subprocess.run(["osmium", "tags-filter", "-O", "-o", str(f), src] + FILTER, check=True)
    p = P(want)
    t0 = time.time()
    H(p).apply_file(str(f), locations=True, idx="flex_mem")
    t_parse = time.time() - t0
    f.unlink()
    bpoly = None
    if poly:
        bpoly = read_poly(poly)
        shapely.prepare(bpoly)
    tiles = {}
    for k, subs in p.items.items():
        row = {"zstd": {}, "count": {}}
        for s in SUBS:
            raw = encode(subs.get(s, []))
            row["zstd"][s] = len(ZC.compress(raw)) if raw else 0
            row["count"][s] = len(subs.get(s, []))
        nm = "".join(x for x in p.names.get(k, []))
        raw = bytearray()
        for x in p.names.get(k, []):
            e = x.encode("utf-8")
            put_varint(raw, len(e))
            raw += e
        row["zstd"]["names"] = len(ZC.compress(bytes(raw))) if raw else 0
        row["count"]["names"] = len(p.names.get(k, []))
        if bpoly is not None:
            bd = Band.get(k[0])
            lo = bd.lon0(k[1])
            row["inside"] = bool(shapely.contains(bpoly, shapely.box(lo, bd.lat0, lo + bd.dlon, bd.lat0 + DLAT)))
        tiles[f"{k[0]},{k[1]}"] = row
    out = {"t_parse_s": round(t_parse, 1), "maxrss_MB": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024),
           "counts": dict(p.n), "tiles": tiles}
    res.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(json.dumps({k: v for k, v in out.items() if k != "tiles"}))


if __name__ == "__main__":
    main()
