"""Выгрузка объектов OpenStreetMap для локации (VR-9, VR-10) и упаковка в data/osm/<id>.json.

Запуск (из корня проекта):
    uv run python tools/osm/fetch_osm.py altai [--refresh] [--only=water]

--only=water — перепаковать только водоёмы в уже готовом data/osm/<id>.json (остальные слои
не пересобираются). После — tools/terrain/osm_water.py <id> (канал G маски 10 м).

Берёт центр локации из configs/locations/<id>.json (только чтение) и параметры выгрузки из
configs/world_objects.json → osm (размер квадрата, классы дорог, высоты этажей).
Сырые ответы Overpass API кешируются в ~/.cache/deltaplan_osm/<id>_<слой>.json
(--refresh — скачать заново). Результат — компактный JSON в координатах мира игры
(та же проекция, что scripts/terrain/geo.gd): x — восток, z — юг, м, округлено до 0,1 м.

Лицензия данных: ODbL 1.0, «© OpenStreetMap contributors» (пишется в файл и в ASSETS.md).
"""

import json
import math
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = Path.home() / ".cache" / "deltaplan_osm"
EARTH_R_M = 6371008.8  # тот же радиус, что в scripts/terrain/geo.gd
ATTRIBUTION = "© OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright)"
USER_AGENT = "deltaplan-sim/0.1 (hang gliding simulator; offline data prep)"

# Слои запроса: имя → тело Overpass QL (bbox подставляется). Разбито, чтобы не упираться в лимиты.
QUERIES = {
    "roads": 'way["highway"]({bbox});',
    "buildings": 'way["building"]({bbox});',
    "power": 'way["power"~"^(line|minor_line)$"]({bbox});node["power"~"^(tower|pole)$"]({bbox});',
    "water": ('way["waterway"~"^(river|stream|canal)$"]({bbox});'
              'way["natural"="water"]({bbox});relation["natural"="water"]({bbox});'),
    "places": 'node["place"~"^(city|town|village|hamlet|suburb|isolated_dwelling)$"]({bbox});',
    "landuse": ('way["landuse"~"^(meadow|grass|farmland)$"]({bbox});'
                'way["barrier"~"^(fence|wall)$"]({bbox});'),
}


def load_json(rel: str) -> dict:
    with open(ROOT / rel, encoding="utf-8") as f:
        return json.load(f)


class Proj:
    """Локальная равнопромежуточная проекция вокруг центра (как TerrainGeo)."""

    def __init__(self, lat0: float, lon0: float):
        self.lat0, self.lon0 = lat0, lon0
        self.m_lat = EARTH_R_M * math.pi / 180.0
        self.m_lon = self.m_lat * math.cos(math.radians(lat0))

    def xz(self, lat: float, lon: float) -> tuple[float, float]:
        return (lon - self.lon0) * self.m_lon, -(lat - self.lat0) * self.m_lat

    def bbox(self, half_m: float) -> tuple[float, float, float, float]:
        dlat = half_m / self.m_lat
        dlon = half_m / self.m_lon
        return self.lat0 - dlat, self.lon0 - dlon, self.lat0 + dlat, self.lon0 + dlon


def overpass(urls: list, body: str, bbox: tuple, timeout_s: int) -> dict:
    """Запрос к Overpass; при ошибке — следующее зеркало из списка, по кругу."""
    b = ",".join(f"{v:.5f}" for v in bbox)
    q = f"[out:json][timeout:{timeout_s}];({body.format(bbox=b)});out body geom;"
    data = urllib.parse.urlencode({"data": q}).encode()
    for attempt in range(3 * len(urls)):
        url = urls[attempt % len(urls)]
        req = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=timeout_s + 30) as r:
                return json.loads(r.read())
        except Exception as e:  # noqa: BLE001 — сеть: повторяем с паузой
            print(f"  Overpass {url}: {e}, повтор {attempt + 1}")
            time.sleep(5 * (attempt + 1))
    raise RuntimeError("Overpass недоступен")


def fetch(loc_id: str, layer: str, cfg: dict, bbox: tuple, refresh: bool) -> dict:
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f"{loc_id}_{layer}.json"
    if path.exists() and not refresh:
        return json.loads(path.read_text())
    print(f"Скачиваю {layer}…")
    res = overpass(cfg["overpass_urls"], QUERIES[layer], bbox, int(cfg["timeout_s"]))
    path.write_text(json.dumps(res))
    time.sleep(2)
    return res


def r1(v: float) -> float:
    return round(v, 1)


def way_xz(proj: Proj, el: dict) -> list[tuple[float, float]]:
    return [proj.xz(g["lat"], g["lon"]) for g in el.get("geometry", []) if g]


def flat(pts: list) -> list:
    out = []
    for x, z in pts:
        out += [r1(x), r1(z)]
    return out


def min_area_rect(pts: list) -> tuple:
    """Минимальный описанный прямоугольник по рёбрам многоугольника: (cx, cz, w, l, угол_рад).

    w — вдоль ребра (ось X' после поворота на угол), l — поперёк."""
    best = None
    n = len(pts)
    for i in range(n):
        x0, z0 = pts[i]
        x1, z1 = pts[(i + 1) % n]
        a = math.atan2(z1 - z0, x1 - x0)
        c, s = math.cos(a), math.sin(a)
        us = [x * c + z * s for x, z in pts]
        vs = [-x * s + z * c for x, z in pts]
        area = (max(us) - min(us)) * (max(vs) - min(vs))
        if best is None or area < best[0]:
            best = (area, a, min(us), max(us), min(vs), max(vs))
    _, a, u0, u1, v0, v1 = best
    c, s = math.cos(a), math.sin(a)
    cu, cv = (u0 + u1) / 2, (v0 + v1) / 2
    return cu * c - cv * s, cu * s + cv * c, u1 - u0, v1 - v0, a


def parse_float(v, default: float) -> float:
    try:
        return float(str(v).split(";")[0].replace(",", ".").replace("m", "").strip())
    except (TypeError, ValueError):
        return default


def pack_roads(proj: Proj, raw: dict, cfg: dict) -> list:
    classes = cfg["road_classes"]
    out = []
    for el in raw["elements"]:
        t = el.get("tags", {}).get("highway")
        if el["type"] != "way" or t not in classes:
            continue
        pts = way_xz(proj, el)
        if len(pts) >= 2:
            out.append({"t": t, "p": flat(pts)})
    return out


def pack_buildings(proj: Proj, raw: dict, cfg: dict) -> list:
    """[x, z, w, l, угол_град, высота_стен_м, крыша] — крыша: 0 двускатная, 1 плоская."""
    level_m = cfg["level_height_m"]
    out = []
    for el in raw["elements"]:
        if el["type"] != "way":
            continue
        tags = el.get("tags", {})
        pts = way_xz(proj, el)
        if len(pts) < 4:
            continue
        pts = pts[:-1] if pts[0] == pts[-1] else pts
        cx, cz, w, ln, a = min_area_rect(pts)
        if w < cfg["min_building_size_m"] or ln < cfg["min_building_size_m"]:
            continue
        kind = tags.get("building", "yes")
        levels = parse_float(tags.get("building:levels"), 0.0)
        height = parse_float(tags.get("height"), 0.0)
        if height <= 0.0:
            if levels <= 0.0:
                levels = cfg["default_levels"].get(kind, cfg["default_levels"]["_other"])
            height = levels * level_m
        roof = tags.get("roof:shape", "")
        flat_roof = roof == "flat" or (roof == "" and (levels >= cfg["flat_roof_min_levels"]
                                                        or kind in cfg["flat_roof_kinds"]))
        out.append([r1(cx), r1(cz), r1(w), r1(ln), round(math.degrees(a), 1), r1(height),
                    1 if flat_roof else 0])
    return out


def pack_power(proj: Proj, raw: dict) -> list:
    """Линии: {k: line|minor_line, v: кВ, c: проводов, p: [x,z…], s: [1 — опора в узле]}."""
    supports = {}
    for el in raw["elements"]:
        if el["type"] == "node":
            supports[el["id"]] = el.get("tags", {}).get("power", "")
    out = []
    for el in raw["elements"]:
        if el["type"] != "way":
            continue
        tags = el.get("tags", {})
        pts = way_xz(proj, el)
        if len(pts) < 2:
            continue
        kv = parse_float(tags.get("voltage"), 0.0) / 1000.0
        cables = int(parse_float(tags.get("cables"), 0.0))
        flags = [1 if supports.get(nid, "") in ("tower", "pole") else 0
                 for nid in el.get("nodes", [])]
        if len(flags) != len(pts):
            flags = [1] * len(pts)
        out.append({"k": tags.get("power"), "v": r1(kv), "c": cables, "p": flat(pts), "s": flags})
    return out


def join_rings(parts: list) -> list:
    """Собрать замкнутые кольца мультиполигона из линий-участников (по совпадающим концам).

    Русло реки в OSM (natural=water + water=river) — relation, где внешний контур разрезан на
    десятки way: каждый way отдельно, замкнутый хордой, заливал бы пойму между концами — лес
    «в воде» (кромка русла прямой линией через берег). Кольцо, не замкнувшееся стыковкой
    (обрывок данных), замыкается хордой — как раньше, но только оно.
    """
    left = [list(p) for p in parts if len(p) >= 2]
    rings = []
    while left:
        ring = left.pop(0)
        while ring[0] != ring[-1]:
            for k, p in enumerate(left):
                if p[0] == ring[-1]:
                    ring += p[1:]
                elif p[-1] == ring[-1]:
                    ring += p[-2::-1]
                elif p[-1] == ring[0]:
                    ring = p[:-1] + ring
                elif p[0] == ring[0]:
                    ring = p[:0:-1] + ring
                else:
                    continue
                left.pop(k)
                break
            else:
                break
        if len(ring) >= 3:
            rings.append(ring)
    return rings


def point_in_ring(pt: tuple, ring: list) -> bool:
    x, z = pt
    inside = False
    for (x0, z0), (x1, z1) in zip(ring, ring[1:] + ring[:1]):
        if (z0 > z) != (z1 > z) and x < (x1 - x0) * (z - z0) / (z1 - z0) + x0:
            inside = not inside
    return inside


def pack_water(proj: Proj, raw: dict) -> dict:
    """Реки — ломаные {t, n, p}; водоёмы — {n, p: внешний контур, h: [контуры островов]}.

    Мультиполигоны (relation natural=water: русла рек с островами, озёра из нескольких way)
    собираются в кольца (join_rings); острова (role=inner) — дыры своего внешнего кольца.
    """
    rivers, lakes = [], []
    for el in raw["elements"]:
        tags = el.get("tags", {})
        if el["type"] == "way" and "waterway" in tags:
            rivers.append({"t": tags["waterway"], "n": tags.get("name", ""),
                           "p": flat(way_xz(proj, el))})
        elif el["type"] == "way" and tags.get("natural") == "water":
            lakes.append({"n": tags.get("name", ""), "p": flat(way_xz(proj, el))})
        elif el["type"] == "relation":
            roles: dict = {"outer": [], "inner": []}
            for m in el.get("members", []):
                if m.get("role") in roles and m.get("geometry"):
                    geom = [(g["lat"], g["lon"]) for g in m["geometry"] if g]
                    roles[m["role"]].append(geom)
            outers = [[proj.xz(*g) for g in r] for r in join_rings(roles["outer"])]
            inners = [[proj.xz(*g) for g in r] for r in join_rings(roles["inner"])]
            holes: list = [[] for _ in outers]
            for inner in inners:
                for k, outer in enumerate(outers):
                    if point_in_ring(inner[0], outer):
                        holes[k].append(flat(inner))
                        break
            for outer, h in zip(outers, holes):
                lake = {"n": tags.get("name", ""), "p": flat(outer)}
                if h:
                    lake["h"] = h
                lakes.append(lake)
    return {"rivers": rivers, "lakes": lakes}


def pack_places(proj: Proj, raw: dict) -> list:
    out = []
    for el in raw["elements"]:
        tags = el.get("tags", {})
        x, z = proj.xz(el["lat"], el["lon"])
        out.append({"n": tags.get("name:ru", tags.get("name", "")), "t": tags.get("place"),
                    "x": r1(x), "z": r1(z), "pop": int(parse_float(tags.get("population"), 0))})
    return out


def pack_landuse(proj: Proj, raw: dict) -> dict:
    fields, fences = [], []
    for el in raw["elements"]:
        tags = el.get("tags", {})
        if el["type"] != "way":
            continue
        if "barrier" in tags:
            fences.append({"t": tags["barrier"], "p": flat(way_xz(proj, el))})
        else:
            fields.append({"t": tags.get("landuse"), "p": flat(way_xz(proj, el))})
    return {"fields": fields, "fences": fences}


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    refresh = "--refresh" in sys.argv
    loc_id = args[0] if args else "altai"
    loc = load_json(f"configs/locations/{loc_id}.json")
    cfg = load_json("configs/world_objects.json")["osm"]
    proj = Proj(float(loc["center_lat"]), float(loc["center_lon"]))
    half = float(cfg["half_size_m"])
    layers = loc.get("dem", {}).get("layers", [])
    if layers:  # квадрат детального слоя рельефа локации
        half = float(layers[0]["size_km"]) * 500.0
    bbox = proj.bbox(half)
    dst = ROOT / "data" / "osm" / f"{loc_id}.json"
    only = next((a[7:] for a in sys.argv if a.startswith("--only=")), "")
    if only == "water":  # перепаковать только водоёмы (кеш Overpass), остальное в файле не трогать
        out = json.loads(dst.read_text())
        out["water"] = pack_water(proj, fetch(loc_id, "water", cfg, bbox, refresh))
        dst.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
        print(f"{dst}: рек {len(out['water']['rivers'])}, водоёмов {len(out['water']['lakes'])}")
        return
    raw = {k: fetch(loc_id, k, cfg, bbox, refresh) for k in QUERIES}
    out = {
        "_doc": "Сгенерировано tools/osm/fetch_osm.py — не править руками. Координаты мира, м.",
        "attribution": ATTRIBUTION,
        "location": loc_id,
        "center_lat": proj.lat0,
        "center_lon": proj.lon0,
        "bbox_latlon": [round(v, 5) for v in bbox],
        "roads": pack_roads(proj, raw["roads"], cfg),
        "buildings": pack_buildings(proj, raw["buildings"], cfg),
        "power": pack_power(proj, raw["power"]),
        "water": pack_water(proj, raw["water"]),
        "places": pack_places(proj, raw["places"]),
        "landuse": pack_landuse(proj, raw["landuse"]),
    }
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
    print(f"{dst}: {dst.stat().st_size / 1e6:.2f} МБ; дорог {len(out['roads'])}, "
          f"зданий {len(out['buildings'])}, ЛЭП {len(out['power'])}, "
          f"рек {len(out['water']['rivers'])}, водоёмов {len(out['water']['lakes'])}, "
          f"пунктов {len(out['places'])}, полей {len(out['landuse']['fields'])}, "
          f"заборов {len(out['landuse']['fences'])}")


if __name__ == "__main__":
    main()
