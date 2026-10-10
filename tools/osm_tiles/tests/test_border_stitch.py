"""Автотест сшивки регионов на границе выгрузок (OT-4; повторно — на итоге оркестратора OT-6).

    python3 test_border_stitch.py --tiles <корень итоговых тайлов, с v1/> --ref-pbf <объединённая выгрузка .osm.pbf>
                                  --border <файл со строками "j i"> [--frags <frag-dir>] [--work <dir>] [--max-tiles N]

Решение пользователя: объекты, пересекающие границу выгрузок (дороги, реки, ЛЭП, дома), — в итоговом тайле
ровно один раз и целиком. Эталон — объединённая выгрузка (`osmium merge` исходных регионов), из неё по
каждому пограничному тайлу `osmium extract` (по прямоугольнику тайла, strategy smart) → geojson; линии
клипуются по тайлу в проекции O1 и считаются. Проверки по каждому тайлу:
  - дороги, track, ЛЭП, реки, каналы, железные дороги: суммарная длина частей в тайле = эталон ±1 %
    (допуск не меньше 25 м абсолютных — на упрощение 1 м и округление; дубль объекта дал бы +100 %,
    потерянный на шве — минус его длина);
  - дома (≥ 50 м², по центроиду): число в тайле в коридоре эталона (коридор: на кромке тайла и при площади около 50 м² ±3 пересчёт
    не тот же, что в упаковщике);
  - в тайле нет двух одинаковых по геометрии линий одного потока (дубль пути);
  - если есть фрагменты (--frags, по умолчанию <tiles>/../frag): число объектов потока в тайле не больше, чем
    даёт правило O4 по ключам (ключи OSM есть только во фрагментах) — ключи без дублей.
Печатает строки по тайлам с расхождениями и в конце `PASS ...` или `FAIL ...` (код выхода 0 / 1).
Нужны osmium-tool и zstd для Python (при отсутствии скрипт сам перезапускается интерпретатором venv эталона).
"""
import argparse
import json
import math
import resource
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _env  # noqa: E402,F401
from border_compare import expected_counts, load, parse_tiles  # noqa: E402

R = 6371008.8
M = math.pi * R / 180
DLAT = 0.18
T = 20000
LEN_TOL_PCT = 1.0
LEN_TOL_ABS_M = 25.0
MIN_AREA = 50.0
EDGE_M = 3.0  # дом на кромке тайла: расхождение центроида упаковщика и этого скрипта
AREA_EPS = 3.0  # то же для площади около 50 м²
# osmium берёт путь, если в bbox есть его узел; длинный сегмент без узлов в тайле иначе потерян в эталоне
EXTRACT_MARGIN = 0.1
BATCH = 4  # выходов osmium extract за проход

ROAD_CLASSES = {"motorway", "trunk", "primary", "secondary", "tertiary", "motorway_link", "trunk_link",
                "primary_link", "secondary_link", "tertiary_link", "unclassified", "residential",
                "living_street", "road"}
LINE_STREAMS = {  # поток → отбор по тегам (O3)
    "roads": lambda p: p.get("highway") in ROAD_CLASSES,
    "track": lambda p: p.get("highway") == "track",
    "powerline": lambda p: p.get("power") in ("line", "minor_line"),
    "river": lambda p: p.get("waterway") == "river",
    "canal": lambda p: p.get("waterway") == "canal",
    "rail": lambda p: p.get("railway") in ("rail", "narrow_gauge"),
}
FILTER = ["w/highway", "w/power=line,minor_line", "w/waterway=river,canal", "w/railway=rail,narrow_gauge",
          "nwr/building"]


class Grid:
    """Тайл O1: прямоугольник в проекции пояса."""

    def __init__(self, j, i):
        self.j, self.i = j, i
        latc = (j + 0.5) * DLAT
        self.kx = M * math.cos(math.radians(latc))
        n = max(1, math.floor(360 * self.kx / T))
        self.dlon = 360 / n
        self.lon0 = -180 + i * self.dlon
        self.lat0 = j * DLAT
        self.W = self.dlon * self.kx
        self.H = DLAT * M

    def bbox(self, margin=0.0):
        """Прямоугольник тайла, градусы; margin — запас в долях размера тайла."""
        dx, dy = self.dlon * margin, DLAT * margin
        return (self.lon0 - dx, self.lat0 - dy, self.lon0 + self.dlon + dx, self.lat0 + DLAT + dy)

    def xy(self, lon, lat):
        return (lon - self.lon0) * self.kx, (lat - self.lat0) * M


def clip_seg(a, b, W, H):
    """Отрезок a-b, обрезанный по [0,W]x[0,H] (Лианга — Барски) → (a', b') или None."""
    t0, t1 = 0.0, 1.0
    dx, dy = b[0] - a[0], b[1] - a[1]
    for p, q in ((-dx, a[0]), (dx, W - a[0]), (-dy, a[1]), (dy, H - a[1])):
        if p == 0:
            if q < 0:
                return None
        else:
            r = q / p
            if p < 0:
                t0 = max(t0, r)
            else:
                t1 = min(t1, r)
            if t0 > t1:
                return None
    return ((a[0] + t0 * dx, a[1] + t0 * dy), (a[0] + t1 * dx, a[1] + t1 * dy))


def clipped_length(pts, g):
    """Длина части ломаной (lon, lat) внутри тайла, м."""
    xy = [g.xy(lo, la) for lo, la in pts]
    s = 0.0
    for a, b in zip(xy, xy[1:]):
        c = clip_seg(a, b, g.W, g.H)
        if c:
            s += math.dist(*c)
    return s


def ring_area_centroid(ring, g):
    """Площадь (м², знаковая) и центроид (lon, lat по средним координатам) кольца."""
    xy = [g.xy(lo, la) for lo, la in ring]
    a = 0.0
    for p, q in zip(xy, xy[1:]):
        a += p[0] * q[1] - q[0] * p[1]
    return a / 2


def polygon_area(rings, g):
    outer = abs(ring_area_centroid(rings[0], g))
    return outer - sum(abs(ring_area_centroid(r, g)) for r in rings[1:])


def polygon_centroid(ring):
    """Центроид внешнего кольца в градусах (площадной; для вырожденного — среднее)."""
    ox, oy = ring[0]  # от первой точки: иначе при координатах ~70° теряется точность (ошибка до десятков метров)
    ring = [(x - ox, y - oy) for x, y in ring]
    a = cx = cy = 0.0
    for (x0, y0), (x1, y1) in zip(ring, ring[1:]):
        c = x0 * y1 - x1 * y0
        a += c
        cx += (x0 + x1) * c
        cy += (y0 + y1) * c
    if abs(a) < 1e-18:
        return ox + sum(p[0] for p in ring) / len(ring), oy + sum(p[1] for p in ring) / len(ring)
    return ox + cx / (3 * a), oy + cy / (3 * a)


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"FAIL: {' '.join(cmd[:3])}…: {r.stderr.strip()[:400]}")


def build_reference(ref_pbf, tiles, work):
    """osmium: фильтр тегов → multi-extract по тайлам → geojsonseq на тайл. → {(j, i): путь .geojsonseq}."""
    filt = work / "filtered.osm.pbf"
    if not filt.exists():
        run(["osmium", "tags-filter", "-f", "pbf", "-o", str(filt), "--overwrite", str(ref_pbf)] + FILTER)
    (work / "ex").mkdir(exist_ok=True)
    # smart с многими выходами за проход держит битовые карты id на каждый выход (>11 ГБ на 74) — пачками
    for k in range(0, len(tiles), BATCH):
        cfg = {"directory": str(work / "ex"), "extracts": [
            {"output": f"{j}_{i}.osm.pbf", "bbox": list(Grid(j, i).bbox(EXTRACT_MARGIN))} for j, i in tiles[k:k + BATCH]]}
        (work / "extract.json").write_text(json.dumps(cfg))
        run(["osmium", "extract", "-s", "smart", "-c", str(work / "extract.json"), "--overwrite", str(filt)])
    out = {}
    for j, i in tiles:
        src, dst = work / "ex" / f"{j}_{i}.osm.pbf", work / "ex" / f"{j}_{i}.geojsonseq"
        run(["osmium", "export", "-f", "geojsonseq", "--overwrite", "-o", str(dst), "--add-unique-id=type_id",
             "-x", "print_record_separator=false", str(src)])
        out[(j, i)] = dst
    return out


def reference_tile(path, g):
    """-> (длины по потокам, (нижняя, верхняя граница числа домов ≥ 50 м² с центроидом в тайле)).

    Центроид и площадь считаются здесь иначе, чем в упаковщике (пересчёт градусы → метры), поэтому дома на
    самой кромке тайла (центроид в пределах EDGE_M) и с площадью около 50 м² (±AREA_EPS) дают коридор:
    нижняя граница — строго внутри и площадь ≥ 50 + AREA_EPS, верхняя — с запасом по кромке и площади.
    Дубль или потеря дома на шве выводят число за коридор."""
    lengths = defaultdict(float)
    lo = hi = 0
    for line in open(path, encoding="utf-8"):
        line = line.strip().lstrip("\x1e")
        if not line:
            continue
        f = json.loads(line)
        geom, p = f["geometry"], f.get("properties", {})
        t = geom["type"]
        if t == "LineString":
            for name, sel in LINE_STREAMS.items():
                if sel(p):
                    lengths[name] += clipped_length(geom["coordinates"], g)
        elif t in ("Polygon", "MultiPolygon") and p.get("building", "no") != "no":
            polys = [geom["coordinates"]] if t == "Polygon" else geom["coordinates"]
            for rings in polys:
                x, y = g.xy(*polygon_centroid(rings[0]))
                area = polygon_area(rings, g)
                if (-EDGE_M <= x < g.W + EDGE_M and -EDGE_M <= y < g.H + EDGE_M) and area >= MIN_AREA - AREA_EPS:
                    hi += 1
                    if 0 <= x < g.W and 0 <= y < g.H and area >= MIN_AREA + AREA_EPS:
                        lo += 1
    return dict(lengths), (lo, hi)


def tile_lengths(t):
    L = defaultdict(float)
    dup = 0
    for s in t["streams"]:
        if s["kind"] not in LINE_STREAMS:
            continue
        seen = set()
        for o in s["objects"]:
            pts = o["pts"]
            L[s["kind"]] += sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))
            k = (o["cls"], tuple(map(tuple, pts)))
            dup += k in seen
            seen.add(k)
    n_b = next((s["count"] for s in t["streams"] if s["kind"] == "buildings"), 0)
    return dict(L), n_b, dup


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tiles", required=True, help="корень итоговых тайлов (с v1/)")
    ap.add_argument("--ref-pbf", required=True, help="объединённая выгрузка (эталон склейки)")
    ap.add_argument("--border", required=True, help="файл со строками 'j i' пограничных тайлов")
    ap.add_argument("--frags", help="каталог фрагментов (по умолчанию <tiles>/../frag, если есть)")
    ap.add_argument("--work", help="рабочий каталог osmium (по умолчанию временный; можно переиспользовать)")
    ap.add_argument("--max-tiles", type=int, default=0, help="только первые N тайлов списка (отладка)")
    o = ap.parse_args(argv)
    tiles = parse_tiles(o.border)
    if o.max_tiles:
        tiles = tiles[:o.max_tiles]
    frags = Path(o.frags) if o.frags else Path(o.tiles).parent / "frag"
    frags = frags if frags.is_dir() else None
    tmp = None
    if o.work:
        work = Path(o.work)
        work.mkdir(parents=True, exist_ok=True)
    else:
        tmp = tempfile.TemporaryDirectory(prefix="border_stitch_")
        work = Path(tmp.name)
    try:
        refs = build_reference(o.ref_pbf, tiles, work)
        bad, rows = [], []
        tot_a, tot_r = defaultdict(float), defaultdict(float)
        b_a = b_r = dups = key_over = missing = 0
        for j, i in tiles:
            g = Grid(j, i)
            rl, (rb_lo, rb) = reference_tile(refs[(j, i)], g)
            t = load(o.tiles, j, i)
            if t is None:
                if any(v > 0 for v in rl.values()) or rb_lo:
                    bad.append(f"{j} {i}: тайла нет, а в эталоне есть объекты")
                    missing += 1
                continue
            al, ab, d = tile_lengths(t)
            dups += d
            if d:
                bad.append(f"{j} {i}: {d} линий-дублей по геометрии")
            for name in LINE_STREAMS:
                a, r = al.get(name, 0.0), rl.get(name, 0.0)
                tot_a[name] += a
                tot_r[name] += r
                tol = max(r * LEN_TOL_PCT / 100, LEN_TOL_ABS_M)
                if abs(a - r) > tol:
                    bad.append(f"{j} {i} {name}: длина тайла {a:.0f} м, эталон {r:.0f} м ({(a - r) / max(r, 1) * 100:+.2f} %)")
            b_a += ab
            b_r += rb_lo
            if not rb_lo <= ab <= rb:
                bad.append(f"{j} {i} дома: тайл {ab}, эталон {rb_lo}..{rb}")
            if frags:
                exp, _ = expected_counts(frags, j, i)
                if exp is not None:
                    for s in t["streams"]:
                        if s["kind"] != "names" and s["count"] > exp.get(s["kind"], 0):
                            key_over += s["count"] - exp[s["kind"]]
                            bad.append(f"{j} {i} {s['kind']}: объектов {s['count']} больше, чем по ключам {exp.get(s['kind'], 0)}")
        print(f"пик памяти osmium (наибольший дочерний процесс): {resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024:.0f} МБ")
        for b in bad:
            print("  ", b)
        print(f"тайлов: {len(tiles)}; длины, км (тайлы / эталон):", ", ".join(
            f"{k} {tot_a[k] / 1000:.1f}/{tot_r[k] / 1000:.1f}" for k in LINE_STREAMS))
        print(f"дома: {b_a} / {b_r}; линий-дублей: {dups}; лишних по ключам: {key_over if frags else 'n/a'}")
        if bad:
            print(f"FAIL: расхождений {len(bad)}")
            return 1
        print(f"PASS: {len(tiles)} пограничных тайлов, длины ±{LEN_TOL_PCT:g} %, дома совпадают, дублей нет")
        return 0
    finally:
        if tmp:
            tmp.cleanup()


if __name__ == "__main__":
    sys.exit(main())
