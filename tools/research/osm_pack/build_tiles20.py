"""Замер слоя «дороги + дома» тайлами 20×20 км на ОДНОЙ мировой сетке (docs/plan/osm_vector_pack.md §9).

    python -I build_tiles20.py <in.osm.pbf> <res.json> [--poly=file.poly] [--want=j,i;j,i;...]

Сетка: пояс j = floor(lat/0,18°) (0,18° = 20,02 км); в поясе n = floor(2π·R·cos(lat_c)/20 км) тайлов
по долготе, шаг 360/n (ширина 20,0–20,5 км), индекс i = floor((lon+180)/шаг). Координаты внутри
тайла — метры от юго-западного угла: x = (lon-lon0)·M·cos(lat_c), y = (lat-lat0)·M (равнопромежуточная
по широте центра пояса), сетка 1 м, ДП 1 м. Без перекрытий, один файл на тайл.
Потоки (каждый zstd 19 отдельно, дельты zigzag-varint):
  roads    motorway..tertiary, unclassified, residential, living_street, road, *_link
  track    highway=track
  bpoly    дома контуром (внешнее кольцо + дыры), тип+крыша кодом, высота/этажи
  brect    дома ориентированным мин. прямоугольником [x, z, w, l, угол, высота, тип]
Дороги клипуются по тайлу; дом относится к тайлу своего центроида (без клипа).
"""
from __future__ import annotations

import json
import math
import resource
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import osmium
import shapely
import zstandard

sys.path.insert(0, str(Path(__file__).parent))
from osmpack import R_EARTH, put_varint, zz  # noqa: E402

T = 20000.0
ROADS = {"motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential",
         "living_street", "road"}
MAJOR = {"motorway", "trunk", "primary", "secondary", "tertiary"}
MAJOR |= {r + "_link" for r in MAJOR}
ROADS |= {r + "_link" for r in ("motorway", "trunk", "primary", "secondary", "tertiary")}
ROOFS = ["", "flat", "gabled", "hipped", "pitched", "skillion", "dome", "other"]
ZC = zstandard.ZstdCompressor(level=19)


def num(s):
    if not s:
        return None
    try:
        return float(s.replace(",", ".").split()[0].rstrip("m"))
    except ValueError:
        return None


def road_stream(tags):
    h = tags.get("highway")
    if h == "track":
        return "track"
    return "roads" if h in ROADS else None


DLAT = 0.18
M_PER_DEG = math.pi * R_EARTH / 180.0


class Band:
    cache = {}

    def __init__(self, j):
        self.j = j
        self.lat0 = j * DLAT
        latc = (j + 0.5) * DLAT
        self.kx = M_PER_DEG * math.cos(math.radians(latc))
        self.ky = M_PER_DEG
        self.n = max(1, int(360 * self.kx // 20000))
        self.dlon = 360.0 / self.n

    @classmethod
    def get(cls, j):
        if j not in cls.cache:
            cls.cache[j] = cls(j)
        return cls.cache[j]

    def lon0(self, i):
        return -180.0 + i * self.dlon


def tiles_in_bbox(x0, y0, x1, y1):
    for j in range(math.floor(y0 / DLAT), math.floor(y1 / DLAT) + 1):
        bd = Band.get(j)
        for i in range(max(0, math.floor((x0 + 180) / bd.dlon)),
                       min(bd.n - 1, math.floor((x1 + 180) / bd.dlon)) + 1):
            yield (j, i)


def tile_of(lon, lat):
    j = math.floor(lat / DLAT)
    bd = Band.get(j)
    return (j, min(bd.n - 1, max(0, math.floor((lon + 180) / bd.dlon))))


def local(g, key):
    bd = Band.get(key[0])
    o = (bd.lon0(key[1]), bd.lat0)
    k = (bd.kx, bd.ky)
    return shapely.transform(g, lambda a: (a - o) * k)


class Tiles:
    def __init__(self, want=None):
        self.want = want
        self.roads = defaultdict(lambda: defaultdict(list))
        self.b = defaultdict(list)
        self.len_m = defaultdict(Counter)
        self.ncls = {}
        self.stat = Counter()
        self.stat_t = defaultdict(Counter)

    def tile_ok(self, key):
        return self.want is None or key in self.want

    # ---- дороги
    def add_road(self, g, tags, st):
        x0, y0, x1, y1 = g.bounds
        w = num(tags.get("width"))
        lanes = num(tags.get("lanes"))
        fl = ((1 if w else 0) | (2 if lanes else 0)
              | (8 if tags.get("tunnel") in ("yes", "building_passage", "culvert") else 0)
              | (16 if tags.get("bridge") not in (None, "no") else 0))
        c = self.cls(tags["highway"])
        ks = list(tiles_in_bbox(x0, y0, x1, y1))
        for key in ks:
            if not self.tile_ok(key):
                continue
            bd = Band.get(key[0])
            lo = bd.lon0(key[1])
            gg = g if len(ks) == 1 else shapely.clip_by_rect(g, lo, bd.lat0, lo + bd.dlon, bd.lat0 + DLAT)
            if gg.is_empty:
                continue
            gg = local(gg, key)
            self.len_m[key][st] += gg.length
            if st == "roads" and tags["highway"] in MAJOR:
                self.len_m[key]["roads_major"] += gg.length
            gg = shapely.simplify(gg, 1.0)
            for p in shapely.get_parts(gg):
                if p.geom_type != "LineString":
                    continue
                a = np.rint(np.asarray(p.coords)).astype(np.int64)
                keep = np.concatenate([[True], np.any(np.diff(a, axis=0) != 0, axis=1)])
                a = a[keep]
                if len(a) < 2:
                    continue
                it = (c, fl, int(round(w * 10)) if w else None, int(lanes) if lanes else None, a)
                self.roads[key][st].append(it)
                if st == "roads" and tags["highway"] in MAJOR:   # подмножество для пресета
                    self.roads[key]["roads_major"].append(it)

    # ---- дома
    def add_building(self, mp, tags):
        bt = tags.get("building", "yes")
        roof = tags.get("roof:shape", "")
        h = num(tags.get("height"))
        lev = num(tags.get("building:levels"))
        for p0 in shapely.get_parts(mp):
            if p0.geom_type != "Polygon":
                continue
            c0 = p0.centroid
            key = tile_of(c0.x, c0.y)
            if not self.tile_ok(key):
                continue
            p = local(p0, key)
            if p.area < 1.0:
                continue
            st = self.stat_t[key]
            for s_ in (self.stat, st):
                s_["total"] += 1
                if h:
                    s_["with_height"] += 1
                elif lev:
                    s_["with_levels_only"] += 1
                if h or lev:
                    s_["with_height_or_levels"] += 1
            tcode = self.cls(("b:" + bt) if bt in (
                "house", "apartments", "residential", "yes", "commercial", "industrial", "retail",
                "garage", "garages", "shed", "detached", "terrace", "church", "school", "roof",
                "office", "hotel", "warehouse", "farm", "barn", "hut", "cabin", "service", "public",
                "civic", "construction") else "b:other")
            rcode = ROOFS.index(roof) if roof in ROOFS else 7
            r = p.minimum_rotated_rectangle
            if r.geom_type != "Polygon":
                continue
            rc = np.asarray(r.exterior.coords)[:4]
            e1, e2 = rc[1] - rc[0], rc[2] - rc[1]
            l1, l2 = np.hypot(*e1), np.hypot(*e2)
            if l1 < l2:
                e1, l1, l2 = e2, l2, l1
            ang = math.degrees(math.atan2(e1[1], e1[0])) % 180.0
            iou = p.intersection(r).area / p.union(r).area
            for s_ in (self.stat, st):
                s_["rect_bad_iou<0.8"] += int(iou < 0.8)
                s_["rect_bad_iou<0.9"] += int(iou < 0.9)
            ctr = r.centroid
            hq = max(0, int(round((h if h else (lev * 3.0 if lev else 0)) * 2)))
            rect = (int(round(ctr.x)), int(round(ctr.y)), int(round(l2 * 2)), int(round(l1 * 2)),
                    int(round(ang)) % 180, hq, tcode, 1 if (not h and lev) else 0)
            ps = shapely.simplify(p, 1.0, preserve_topology=True)
            if ps.geom_type != "Polygon" or ps.is_empty:
                ps = p
            rings = []
            for rg in [ps.exterior] + list(ps.interiors):
                a = np.rint(np.asarray(rg.coords)[:-1]).astype(np.int64)
                keep = np.concatenate([[True], np.any(np.diff(a, axis=0) != 0, axis=1)]) if len(a) > 1 else np.array([True])
                a = a[keep]
                if len(a) >= 3:
                    rings.append(a)
            if not rings:
                continue
            attrs = (tcode * 8 + rcode, 1 if h else (2 if lev else 0),
                     max(0, int(round(h * 2))) if h else (max(0, int(lev)) if lev else 0))
            self.b[key].append((rect, attrs, rings, p.area))

    def cls(self, name):
        return self.ncls.setdefault(name, len(self.ncls))

    # ---- дороги
def morton(x, y):
    r = 0
    x, y = min(x, 1023), min(y, 1023)
    for i in range(10):
        r |= ((x >> i) & 1) << (2 * i) | ((y >> i) & 1) << (2 * i + 1)
    return r


def enc_pts(buf, a, lx, ly):
    for x, y in a.tolist():
        put_varint(buf, zz(x - lx))
        put_varint(buf, zz(y - ly))
        lx, ly = x, y
    return lx, ly


def enc_rects(items):
    br = bytearray()
    rx = ry = 0
    for rect, _, _, _ in items:
        x, y, w, l, ang, hq, tc, lv = rect
        put_varint(br, zz(x - rx))
        put_varint(br, zz(y - ry))
        rx, ry = x, y
        put_varint(br, w)
        put_varint(br, l)
        put_varint(br, ang)
        put_varint(br, hq * 2 + lv)
        put_varint(br, tc)
    return bytes(br)


def enc_polys(items):
    bp = bytearray()
    lx = ly = 0
    for _, (cr, hf, hv), rings, _ in items:
        put_varint(bp, cr)
        bp.append(hf)
        if hf:
            put_varint(bp, hv)
        put_varint(bp, len(rings))
        for a in rings:
            put_varint(bp, len(a))
            lx, ly = enc_pts(bp, a, lx, ly)
    return bytes(bp)


def encode_tile(tr, key):
    """Потоки roads, track, bpoly, brect — основные; roads_major, brect_ge50/100, bpoly_ge100 — подмножества
    (для пресетов, в сумму не входят)."""
    out = {}
    for st in ("roads", "track", "roads_major"):
        buf = bytearray()
        lx = ly = 0
        for c, fl, w, lanes, a in tr.roads[key].get(st, []):
            put_varint(buf, c)
            buf.append(fl)
            if w is not None:
                put_varint(buf, w)
            if lanes is not None:
                put_varint(buf, lanes)
            put_varint(buf, len(a))
            lx, ly = enc_pts(buf, a, lx, ly)
        out[st] = bytes(buf)
    items = sorted(tr.b.get(key, []), key=lambda t: morton(max(t[0][0], 0) >> 6, max(t[0][1], 0) >> 6))
    out["bpoly"], out["brect"] = enc_polys(items), enc_rects(items)
    for th in (50, 100, 200):
        sub = [t for t in items if t[3] >= th]
        out[f"brect_ge{th}"] = enc_rects(sub)
        out[f"bpoly_ge{th}"] = enc_polys(sub)
        out[f"n_ge{th}"] = len(sub)
    return out, len(items)


class H(osmium.SimpleHandler):
    def __init__(self, tr):
        super().__init__()
        self.tr = tr
        self.wkb = osmium.geom.WKBFactory()
        self.fail = Counter()

    def way(self, w):
        t = w.tags
        h = t.get("highway")
        if not h:
            return
        tags = dict(t)
        st = road_stream(tags)
        if not st:
            return
        try:
            g = shapely.from_wkb(self.wkb.create_linestring(w))
        except Exception:
            self.fail["line"] += 1
            return
        self.tr.add_road(g, tags, st)

    def area(self, a):
        b = a.tags.get("building")
        if not b or b == "no":
            return
        try:
            g = shapely.from_wkb(self.wkb.create_multipolygon(a))
        except Exception:
            self.fail["area"] += 1
            return
        self.tr.add_building(g, dict(a.tags))


def read_poly(path):
    rings, cur, hole = [], None, False
    for ln in Path(path).read_text().splitlines():
        t = ln.split()
        if not t:
            continue
        if t[0] == "END":
            if cur:
                rings.append((hole, cur))
            cur = None
        elif len(t) == 1:
            hole = t[0].startswith("!")
            cur = []
        elif cur is not None:
            cur.append((float(t[0]), float(t[1])))
    out = None
    for hole_, pts in rings:
        if not hole_:
            p = shapely.Polygon(pts)
            out = p if out is None else out.union(p)
    for hole_, pts in rings:
        if hole_:
            out = out.difference(shapely.Polygon(pts))
    return out


def main():
    src, res = sys.argv[1], Path(sys.argv[2])
    poly, want = None, None
    for a in sys.argv[3:]:
        if a.startswith("--poly="):
            poly = a[7:]
        if a.startswith("--want="):
            want = {tuple(int(v) for v in t.split(",")) for t in a[7:].split(";")}
    tr = Tiles(want)
    t0 = time.time()
    h = H(tr)
    h.apply_file(src, locations=True, idx="flex_mem")
    t_parse = time.time() - t0
    t1 = time.time()
    keys = sorted(set(tr.roads) | set(tr.b))
    if poly:
        bpoly = read_poly(poly)
        shapely.prepare(bpoly)
    tiles = {}
    for k in keys:
        streams, nb = encode_tile(tr, k)
        bd = Band.get(k[0])
        row = {"streams_raw": {s: len(v) for s, v in streams.items() if isinstance(v, bytes)},
               "streams_zstd": {s: len(ZC.compress(v)) if v else 0 for s, v in streams.items()
                                if isinstance(v, bytes)},
               "n_ge": {s[2:]: v for s, v in streams.items() if isinstance(v, int)},
               "n_buildings": nb, "buildings": dict(tr.stat_t[k]),
               "area_km2": round(bd.dlon * bd.kx * DLAT * bd.ky / 1e6, 1),
               "len_km": {s: round(tr.len_m[k][s] / 1000, 2) for s in ("roads", "roads_major", "track")},
               "n_road_parts": {s: len(tr.roads[k].get(s, [])) for s in ("roads", "roads_major", "track")}}
        if poly:
            lo = bd.lon0(k[1])
            row["inside"] = bool(shapely.contains(bpoly, shapely.box(lo, bd.lat0, lo + bd.dlon, bd.lat0 + DLAT)))
        tiles[f"{k[0]},{k[1]}"] = row
    out = {"source": src, "tile_km": 20, "dlat": DLAT,
           "t_parse_s": round(t_parse, 1), "t_encode_s": round(time.time() - t1, 1),
           "maxrss_MB": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024),
           "buildings": dict(tr.stat), "geom_fail": dict(h.fail), "tiles": tiles,
           "classes": tr.ncls}
    res.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(json.dumps({k: v for k, v in out.items() if k not in ("tiles", "classes")}))


if __name__ == "__main__":
    main()
