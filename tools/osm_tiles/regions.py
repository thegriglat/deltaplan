#!/usr/bin/env python3
"""OT-5: набор регионов Geofabrik и покрытие тайлами (контракт O8).

Модуль (его импортирует world.py) и CLI:
  regions.py plan  --work <dir> [--max-region-gb 2.0] [--osmtiles <бинарь>]
  regions.py check --work <dir>

Только stdlib. Геометрия — растр на равноугольной сетке RES градусов: маска региона — список целых чисел
(по числу на строку широты, бит = ячейка долготы); площадь ячейки — cos(широты). Объединение — OR, пересечение — AND,
отрицательный буфер — сдвиги. Контуры берутся из геометрии index-v1.json (те же полигоны, что .poly, но
упрощённые); сами .poly скачиваются для выбранных регионов — они нужны `osmtiles cover`.
"""
import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

INDEX_URL = "https://download.geofabrik.de/index-v1.json"
USER_AGENT = "deltaplan-osm-tiles/1 (+https://github.com/thegriglat/deltaplan)"
RES = 0.05                       # шаг растра, градусы
W = int(round(360 / RES))
H = int(round(180 / RES))
COVER_FRACTION = 0.99            # дети покрывают узел, если площадь объединения >= 99 %
COMPOSITE_COVERED = 0.80         # сборный: >= 80 % его площади покрыто его частями (меньшими сиблингами внутри него)
COMPOSITE_INSIDE = 0.80          # «часть» лежит внутри сборного на >= 80 % своей площади
CONTAINED = 0.40                 # регион, на >= 50 % лежащий в другом регионе набора, убирается
BUFFER_CELLS = 1                 # отрицательный буфер при подсчёте перекрытий: 1 ячейка = 0,05°
GB = 1e9
HEAD_DELAY_S = 0.3

_ROW_W = [math.cos(math.radians(-90 + (k + 0.5) * RES)) for k in range(H)]
_FULL = (1 << W) - 1


# ---------------------------------------------------------------- геометрия (растр)

def rasterize(geometry):
    """GeoJSON (Polygon|MultiPolygon, lon/lat) -> (rows, k0, k1): маски строк k0..k1-1 (чётно-нечётное правило)."""
    gt = geometry["type"]
    polys = geometry["coordinates"] if gt == "MultiPolygon" else [geometry["coordinates"]]
    rows = {}
    for poly in polys:
        for ring in poly:
            _fill_ring(ring, rows)
    if not rows:
        return {}, 0, 0
    return rows, min(rows), max(rows) + 1


def _fill_ring(ring, rows):
    cross = {}
    n = len(ring)
    for e in range(n - 1 if ring[0] == ring[-1] else n):
        x1, y1 = ring[e][0], ring[e][1]
        x2, y2 = ring[(e + 1) % n][0], ring[(e + 1) % n][1]
        if y1 == y2:
            continue
        if y1 > y2:
            x1, y1, x2, y2 = x2, y2, x1, y1
        # строки k, центр которых y_c в [y1, y2)
        ka = max(0, math.ceil((y1 + 90) / RES - 0.5))
        kb = min(H - 1, math.ceil((y2 + 90) / RES - 0.5) - 1)
        if ka > kb:
            continue
        dx = (x2 - x1) / (y2 - y1)
        for k in range(ka, kb + 1):
            yc = -90 + (k + 0.5) * RES
            cross.setdefault(k, []).append(x1 + (yc - y1) * dx)
    for k, xs in cross.items():
        xs.sort()
        acc = rows.get(k, 0)
        for a in range(0, len(xs) - 1, 2):
            ca = max(0, math.ceil((xs[a] + 180) / RES - 0.5))
            cb = min(W, math.ceil((xs[a + 1] + 180) / RES - 0.5))
            if cb > ca:
                acc ^= ((1 << (cb - ca)) - 1) << ca
        rows[k] = acc


class Mask:
    """Растровая маска: rows — dict строка -> int."""
    __slots__ = ("rows",)

    def __init__(self, rows):
        self.rows = {k: v for k, v in rows.items() if v}

    @classmethod
    def from_geometry(cls, geometry):
        return cls(rasterize(geometry)[0])

    def area(self):
        return sum(_ROW_W[k] * v.bit_count() for k, v in self.rows.items())

    def union(self, other):
        r = dict(self.rows)
        for k, v in other.rows.items():
            r[k] = r.get(k, 0) | v
        return Mask(r)

    def intersect(self, other):
        a, b = (self, other) if len(self.rows) <= len(other.rows) else (other, self)
        return Mask({k: v & b.rows[k] for k, v in a.rows.items() if k in b.rows})

    def intersect_area(self, other):
        a, b = (self, other) if len(self.rows) <= len(other.rows) else (other, self)
        s = 0.0
        for k, v in a.rows.items():
            w = b.rows.get(k)
            if w:
                s += _ROW_W[k] * (v & w).bit_count()
        return s

    def eroded(self, cells=None):
        """Отрицательный буфер на BUFFER_CELLS ячеек (RES каждая): 4-соседство, итерациями."""
        cur = self
        for _ in range(BUFFER_CELLS if cells is None else cells):
            r = {}
            for k, v in cur.rows.items():
                m = v & (v << 1) & (v >> 1) & cur.rows.get(k + 1, 0) & cur.rows.get(k - 1, 0)
                if m:
                    r[k] = m & _FULL
            cur = Mask(r)
        return cur

    def bbox_rows(self):
        return (min(self.rows), max(self.rows)) if self.rows else (0, -1)


def union_all(masks):
    r = {}
    for m in masks:
        for k, v in m.rows.items():
            r[k] = r.get(k, 0) | v
    return Mask(r)


# ---------------------------------------------------------------- индекс / дерево

class Tree:
    def __init__(self, index):
        self.feat = {}
        self.children = {}
        for f in index["features"]:
            p = f["properties"]
            self.feat[p["id"]] = f
            self.children.setdefault(p.get("parent"), []).append(p["id"])
        self._mask = {}

    def prop(self, i):
        return self.feat[i]["properties"]

    def kids(self, i):
        return sorted(self.children.get(i, []))

    def roots(self):
        return sorted(self.children.get(None, []))

    def mask(self, i):
        if i not in self._mask:
            self._mask[i] = Mask.from_geometry(self.feat[i]["geometry"])
        return self._mask[i]

    def drop_mask(self, i):
        self._mask.pop(i, None)

    def pbf_url(self, i):
        return self.prop(i)["urls"]["pbf"]

    def poly_url(self, i):
        return self.pbf_url(i).replace("-latest.osm.pbf", ".poly")

    def md5_url(self, i):
        return self.pbf_url(i) + ".md5"


def drop_covered(tree, sibs):
    """Сборные регионы среди детей одного узла (dach, alps, britain-and-ireland, us, us-west, sea, ...).
    Геометрия, не названия; повторяется, пока что-то убирается. Сиблинг сборный, если
    (1) >= 80 % его площади покрыто его частями — меньшими сиблингами, лежащими внутри него (>= 80 % своей площади), не менее двух; или
    (2) >= 90 % покрыто объединением остальных, вкладывают >= 5 % площади не менее трёх, и он не лежит целиком
        (>= 50 %) внутри одного сиблинга (alps: из кусков Австрии, Швейцарии, Франции, Италии, ...).
    Возвращает (оставшиеся, убранные)."""
    masks = {s: tree.mask(s) for s in sibs}
    area = {s: masks[s].area() for s in sibs}
    rows = {s: (min(masks[s].rows), max(masks[s].rows)) if masks[s].rows else (0, -1) for s in sibs}
    alive = list(sibs)
    dropped = []

    def near(x, s):
        return not (rows[x][1] < rows[s][0] or rows[s][1] < rows[x][0])

    changed = True
    while changed:
        changed = False
        for s in list(alive):
            if area[s] <= 0:
                continue
            parts, contrib, single = [], [], False
            for x in alive:
                if x == s or area[x] <= 0 or not near(x, s):
                    continue
                inter = masks[x].intersect_area(masks[s])
                if area[x] < area[s] and inter / area[x] >= COMPOSITE_INSIDE:
                    parts.append(masks[x])
                if inter / area[s] >= 0.05:
                    contrib.append(masks[x])
                if inter / area[s] >= CONTAINED:
                    single = True
            r1 = len(parts) >= 2 and union_all(parts).intersect_area(masks[s]) / area[s] >= COMPOSITE_COVERED
            r2 = (len(contrib) >= 3 and not single
                  and union_all([masks[x] for x in alive if x != s and near(x, s)]).intersect_area(masks[s]) / area[s] >= 0.9)
            if r1 or r2:
                alive.remove(s)
                dropped.append(s)
                changed = True
    return sorted(alive), sorted(dropped)


def drop_contained(tree, ids):
    """Регион, на >= 50 % лежащий внутри другого региона набора (azores в portugal, isle-of-man в great-britain),
    убирается: его данные уже в чужой выгрузке по её полигону. Возвращает (оставшиеся, [(убранный, внешний, доля)])."""
    masks = {i: tree.mask(i) for i in ids}
    area = {i: masks[i].area() for i in ids}
    kept = list(ids)
    removed = []
    for i in sorted(ids, key=lambda i: area[i]):
        best = (0.0, None)
        for j in kept:
            if j == i or area[j] < area[i]:
                continue
            f = masks[i].intersect_area(masks[j]) / area[i] if area[i] else 0
            if f > best[0]:
                best = (f, j)
        if best[0] >= CONTAINED:
            kept.remove(i)
            removed.append((i, best[1], round(best[0], 2)))
    return kept, removed


# ---------------------------------------------------------------- сеть (вежливо, один поток, кеш)

def http(url, method="GET", timeout=60):
    req = urllib.request.Request(url, method=method, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(req, timeout=timeout)


def retry(fn, tries=4):
    for n in range(tries):
        try:
            return fn()
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            if isinstance(e, urllib.error.HTTPError) and e.code in (403, 404):
                raise
            if n == tries - 1:
                raise
            time.sleep(2 ** n)


def atomic_write(path, data):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    os.replace(tmp, path)


def load_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


class Net:
    def __init__(self, work, offline=False):
        self.work = work
        self.offline = offline
        self.heads_path = os.path.join(work, "heads.json")
        self.heads = load_json(self.heads_path, {})

    def index(self):
        p = os.path.join(self.work, "index-v1.json")
        if not os.path.exists(p):
            log("скачиваю index-v1.json")
            atomic_write(p, retry(lambda: http(INDEX_URL).read()))
        return load_json(p)

    def head_size(self, rid, url):
        h = self.heads.get(rid)
        if h and h.get("url") == url:
            return h["bytes"]
        log("HEAD " + url)
        time.sleep(HEAD_DELAY_S)
        r = retry(lambda: http(url, "HEAD"))
        size = int(r.headers["Content-Length"])
        self.heads[rid] = {"url": url, "bytes": size, "last_modified": r.headers.get("Last-Modified", "")}
        atomic_write(self.heads_path, json.dumps(self.heads, indent=0))
        return size

    def poly(self, rid, url, geometry=None):
        d = os.path.join(self.work, "poly")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, rid + ".poly")
        if not os.path.exists(p) or os.path.getsize(p) == 0:
            log("poly " + url)
            time.sleep(HEAD_DELAY_S)
            body = retry(lambda: http(url).read())
            if b"END" not in body:
                # у части регионов (japan, ...) Geofabrik отдаёт пустой .poly — берём полигон из index-v1.json
                if geometry is None:
                    raise RuntimeError("пустой .poly " + url)
                log("пустой .poly, беру геометрию индекса: " + rid)
                body = geometry_to_poly(rid, geometry).encode()
            atomic_write(p, body)
        return p


def geometry_to_poly(name, geometry):
    """GeoJSON Polygon|MultiPolygon -> текст .poly (Osmosis): кольца, дыры с '!'."""
    polys = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
    out = [name]
    n = 0
    for poly in polys:
        for ri, ring in enumerate(poly):
            n += 1
            out.append(("!" if ri else "") + str(n))
            out += ["   %.7E   %.7E" % (x, y) for x, y in ring]
            out.append("END")
    out.append("END")
    return "\n".join(out) + "\n"


def safe_id(index_id):
    """id региона для имён файлов и --region: 'us/alabama' -> 'us_alabama'."""
    return index_id.replace("/", "_")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- выбор набора (O8)

def choose(tree, head_size, max_bytes, warn=None):
    """Возвращает (список id, предупреждения [str], исключения — id крупнее лимита).

    Узел берётся целиком, если pbf <= max_bytes или нет детей; иначе — дети (без сборных), если объединение
    детей покрывает >= 99 % узла, иначе узел целиком с предупреждением."""
    warns = []
    chosen = []
    over = []
    comps = []

    def visit(i):
        size = head_size(i)
        kids = tree.kids(i)
        if (size <= max_bytes and tree.prop(i).get("parent") is not None) or not kids:
            chosen.append(i)
            if size > max_bytes:
                warns.append("%s: %.2f ГБ > лимита, детей нет — исключение" % (i, size / GB))
                over.append(i)
            return
        good, comp = drop_covered(tree, kids)
        comps.extend(comp)
        if tree.prop(i).get("parent") is None:
            # полигон континента — грубая рамка с морем, площадь детей по нему не меряется; дети берутся всегда
            cov = 1.0
        else:
            node_area = tree.mask(i).area()
            cov = union_all([tree.mask(k) for k in good]).intersect_area(tree.mask(i)) / node_area if node_area else 1.0
        if cov >= COVER_FRACTION:
            if comp:
                warns.append("%s: сборные дети не взяты: %s" % (i, ",".join(comp)))
            for k in good:
                visit(k)
        else:
            warns.append("%s: дети покрывают %.1f %% < 99 %% — узел целиком (%.2f ГБ)" % (i, cov * 100, size / GB))
            chosen.append(i)
            over.append(i)
            # дети, лежащие в основном вне полигона узла (guyane у france, falklands), узлом не покрыты — берутся отдельно
            for k in good:
                km = tree.mask(k)
                if km.area() > 0 and tree.mask(i).intersect_area(km) / km.area() < 0.5:
                    visit(k)

    for r in tree.roots():
        visit(r)
    return chosen, warns, over, comps


def prune_nested(tree, chosen):
    """Если в наборе есть регион и его потомок — оставить потомка нельзя (потомок входит в предка); вызывается
    на случай дублей: предок без пересечений остаётся, потомки убираются."""
    s = set(chosen)
    out = []
    for i in chosen:
        p = tree.prop(i).get("parent")
        nested = False
        while p:
            if p in s:
                nested = True
                break
            p = tree.prop(p).get("parent")
        if not nested:
            out.append(i)
    return out


# ---------------------------------------------------------------- cover

def run_cover(osmtiles, poly, out_path):
    r = subprocess.run([osmtiles, "cover", "--poly", poly], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("osmtiles cover %s: %s" % (poly, r.stderr.strip()[-300:]))
    atomic_write(out_path, r.stdout)
    return r.stdout


def read_cover(path):
    tiles = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) >= 2:
                tiles.append((int(p[0]), int(p[1])))
    return tiles


def count_cover(work, ids):
    """Возвращает (число различных тайлов, число пограничных — тайлов, которые есть в >= 2 cover, отсутствующие id)."""
    seen = {}
    missing = []
    for i in ids:
        p = os.path.join(work, "cover", i + ".txt")
        if not os.path.exists(p):
            missing.append(i)
            continue
        for t in set(read_cover(p)):
            seen[t] = seen.get(t, 0) + 1
    return len(seen), sum(1 for v in seen.values() if v >= 2), missing


# ---------------------------------------------------------------- plan

def cmd_plan(args):
    work = args.work
    os.makedirs(work, exist_ok=True)
    out_path = os.path.join(work, "regions.json")
    if os.path.exists(out_path) and not args.force:
        log("regions.json уже есть (набор заморожен); достраиваю cover")
        data = load_json(out_path)
    else:
        net = Net(work)
        tree = Tree(net.index())
        max_bytes = int(args.max_region_gb * GB)
        chosen, warns, over, comps = choose(tree, lambda i: net.head_size(i, tree.pbf_url(i)), max_bytes)
        chosen = prune_nested(tree, chosen)
        chosen, removed = drop_contained(tree, chosen)
        warns += ["%s: %.0f %% площади внутри %s — убран" % (a, f * 100, b) for a, b, f in removed]
        for w in warns:
            log("ПРЕДУПРЕЖДЕНИЕ: " + w)
        regions = []
        for i in sorted(chosen):
            regions.append({"id": safe_id(i), "index_id": i, "parent": tree.prop(i).get("parent"), "url": tree.pbf_url(i),
                            "poly_url": tree.poly_url(i), "md5_url": tree.md5_url(i),
                            "pbf_bytes": net.heads[i]["bytes"], "tiles": None})
        ids = [safe_id(i) for i in chosen]
        assert len(set(ids)) == len(ids), "дубли id после замены '/'"
        data = {"schema": "osmtiles-regions/1", "max_region_gb": args.max_region_gb,
                "index_sha256": hashlib.sha256(open(os.path.join(work, "index-v1.json"), "rb").read()).hexdigest(),
                "warnings": warns, "oversize_exceptions": [safe_id(i) for i in over], "composites": comps, "regions": regions}
        pm = {r["id"]: tree.mask(r["index_id"]) for r in regions}
        data["overlaps_listed"] = [[a, b, round(p, 1)] for p, a, b in sorted(overlap_pairs(pm), reverse=True)]
        atomic_write(out_path, json.dumps(data, ensure_ascii=False, indent=1))
    net = Net(work)
    tree = Tree(net.index())
    os.makedirs(os.path.join(work, "cover"), exist_ok=True)
    changed = False
    for r in data["regions"]:
        cp = os.path.join(work, "cover", r["id"] + ".txt")
        net.poly(r["id"], r["poly_url"], tree.feat[r["index_id"]]["geometry"])
        if args.recompute_cover and args.osmtiles and os.path.exists(cp):
            os.remove(cp)
        if r.get("tiles") is None or not os.path.exists(cp):
            if not args.osmtiles:
                continue
            if not os.path.exists(cp):
                log("cover " + r["id"])
                run_cover(args.osmtiles, os.path.join(work, "poly", r["id"] + ".poly"), cp)
            r["tiles"] = len(set(read_cover(cp)))
            changed = True
            atomic_write(out_path, json.dumps(data, ensure_ascii=False, indent=1))
    if changed:
        atomic_write(out_path, json.dumps(data, ensure_ascii=False, indent=1))
    print(check_line(work))
    return 0


# ---------------------------------------------------------------- check

def overlap_pairs(masks):
    """Пары с перекрытием > 1 % по растру с отрицательным буфером: [(процент от меньшей площади, a, b)]."""
    ids = sorted(masks)
    er = {i: masks[i].eroded() for i in ids}
    ar = {i: er[i].area() for i in ids}
    rng = {i: er[i].bbox_rows() for i in ids}
    out = []
    for ai, a in enumerate(ids):
        for b in ids[ai + 1:]:
            if rng[a][1] < rng[b][0] or rng[b][1] < rng[a][0]:
                continue
            x = er[a].intersect_area(er[b])
            m = min(ar[a], ar[b])
            if x > 0 and m and 100 * x / m > 1.0:
                out.append((100 * x / m, a, b))
    return out


def check_stats(work):
    data = load_json(os.path.join(work, "regions.json"))
    tree = Tree(load_json(os.path.join(work, "index-v1.json")))
    ids = [r["id"] for r in data["regions"]]
    idx = {r["id"]: r["index_id"] for r in data["regions"]}
    masks = {i: tree.mask(idx[i]) for i in ids}
    pairs = overlap_pairs(masks)
    listed = {(a, b) for a, b, _ in data.get("overlaps_listed", [])}
    unl = [p for p in pairs if (p[1], p[2]) not in listed]
    omax, opair = (max(unl)[0], max(unl)[1:]) if unl else (0.0, None)
    lmax = max([p[0] for p in pairs if (p[1], p[2]) in listed], default=0.0)
    # «суша» = объединение всех некорневых узлов дерева (полигоны континентов — грубые рамки с морем)
    roots = set(tree.roots())
    skip = roots | set(data.get("composites", []))
    land = union_all([tree.mask(i) for i in tree.feat if i not in skip])
    sel = union_all(masks.values())
    cov = 100 * sel.intersect_area(land) / land.area()
    maxb = max(r["pbf_bytes"] for r in data["regions"])
    limit = data["max_region_gb"] * GB
    exc = set(data.get("oversize_exceptions", []))
    over = [r["id"] for r in data["regions"] if r["pbf_bytes"] > limit and r["id"] not in exc]
    ntiles, nborder, missing = count_cover(work, ids)
    return {"regions": len(ids), "total_gb": sum(r["pbf_bytes"] for r in data["regions"]) / GB,
            "overlap_max_pct": omax, "overlap_pair": opair, "overlap_listed": len(listed), "overlap_listed_max_pct": lmax, "coverage_pct": cov, "max_region_gb": maxb / GB,
            "max_region": max(data["regions"], key=lambda r: r["pbf_bytes"])["id"],
            "oversize_unlisted": len(over), "oversize": over, "cover_missing": len(missing),
            "tiles": ntiles, "border_tiles": nborder}


def check_line(work):
    s = check_stats(work)
    return ("regions=%d total_gb=%.1f overlap_max_pct=%.2f coverage_pct=%.2f max_region_gb=%.2f "
            "oversize_unlisted=%d cover_missing=%d tiles=%d border_tiles=%d overlap_listed=%d overlap_listed_max_pct=%.1f"
            % (s["regions"], s["total_gb"], s["overlap_max_pct"], s["coverage_pct"], s["max_region_gb"],
               s["oversize_unlisted"], s["cover_missing"], s["tiles"], s["border_tiles"],
               s["overlap_listed"], s["overlap_listed_max_pct"]))


def cmd_check(args):
    print(check_line(args.work))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--work", required=True)
    p.add_argument("--max-region-gb", type=float, default=2.0)
    p.add_argument("--osmtiles")
    p.add_argument("--recompute-cover", action="store_true", help="пересчитать cover/*.txt (.poly не перекачиваются)")
    p.add_argument("--force", action="store_true", help="пересчитать набор (иначе regions.json заморожен)")
    p.set_defaults(fn=cmd_plan)
    c = sub.add_parser("check")
    c.add_argument("--work", required=True)
    c.set_defaults(fn=cmd_check)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
