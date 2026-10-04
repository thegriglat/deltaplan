"""Чистые функции каталога мест дельтаплана (S6): отбор стартов, кластеризация, сборка выходных файлов.

Без сети: вход — сырые элементы Overpass (nwr с тегами и geometry), выход — строки/места.
"""
import json
import math
from collections import Counter

import numpy as np
from scipy.spatial import cKDTree

EARTH_R_M = 6371008.8
CLUSTER_KM = 10.0
SQUARE_HALF_M = 20000.0

CSV_COLUMNS = ["osm_type", "osm_id", "osm_url", "name", "lat", "lon", "ele_m", "country", "country_name", "country_name_ru", "site",
               "hanggliding", "paragliding", "site_orientation", "tags", "site_id"]


def element_center(el):
    """Центр элемента: node — точка; way/relation — центр bbox геометрии (или поле center)."""
    if el["type"] == "node":
        return el["lat"], el["lon"]
    if "center" in el:
        return el["center"]["lat"], el["center"]["lon"]
    pts = []
    if "geometry" in el:
        pts += [g for g in el["geometry"] if g]
    for m in el.get("members", []):
        pts += [g for g in m.get("geometry", []) if g]
        if m["type"] == "node" and "lat" in m:
            pts.append({"lat": m["lat"], "lon": m["lon"]})
    if "bounds" in el and not pts:
        b = el["bounds"]
        return (b["minlat"] + b["maxlat"]) / 2, (b["minlon"] + b["maxlon"]) / 2
    if not pts:
        return None
    la = [p["lat"] for p in pts]
    lo = [p["lon"] for p in pts]
    return (min(la) + max(la)) / 2, (min(lo) + max(lo)) / 2


def _vals(v):
    return [x.strip() for x in str(v).split(";") if x.strip()]


def is_takeoff(tags):
    """Старт: free_flying:site содержит takeoff (в т. ч. составное) ИЛИ free_flying:takeoff=yes
    (новая схема вики OSM, site=takeoff в ней deprecated)."""
    if "takeoff" in _vals(tags.get("free_flying:site", "")):
        return True
    return "yes" in _vals(tags.get("free_flying:takeoff", ""))


def drop_kind(tags):
    """Вид отброшенного объекта без старта (для сводки)."""
    s = _vals(tags.get("free_flying:site", ""))
    kinds = [v for v in ("landing", "toplanding", "towing", "training") if v in s]
    for k in ("landing", "towing", "training"):
        if "yes" in _vals(tags.get("free_flying:" + k, "")):
            kinds.append(k)
    return "+".join(sorted(set(kinds))) or "other_site"


def hg_class(tags):
    """'hg' (каталог) | 'unclear' | 'paraglide_only' | 'hg_discouraged'."""
    hg = tags.get("free_flying:hanggliding", "")
    pg = tags.get("free_flying:paragliding", "")
    rigid = tags.get("free_flying:rigid", "")
    if "yes" in _vals(hg):
        return "hg"
    if "yes" in _vals(rigid) and "no" not in _vals(hg):
        return "hg"  # жёсткое крыло — дельтаплан
    if "no" in _vals(hg):
        return "paraglide_only"
    if "discouraged" in _vals(hg):
        return "hg_discouraged"
    if "yes" in _vals(pg):
        return "paraglide_only"  # только параплан по контракту S6
    return "unclear"


def parse_ele(v):
    try:
        return float(str(v).split(";")[0].replace(",", ".").replace("m", "").strip())
    except (TypeError, ValueError):
        return None


def select(elements):
    """Сырые элементы → (rows по классам, число отброшенных по видам). Дедуп по (type, id); порядок детерминирован."""
    seen = {}
    for el in elements:
        seen[(el["type"], el["id"])] = el
    rows = {"hg": [], "unclear": [], "paraglide_only": [], "hg_discouraged": []}
    dropped = Counter()
    n_no_center = 0
    for key in sorted(seen, key=lambda k: (k[0], k[1])):
        el = seen[key]
        tags = el.get("tags", {})
        if not is_takeoff(tags):
            dropped[drop_kind(tags)] += 1
            continue
        c = element_center(el)
        if c is None:
            n_no_center += 1
            continue
        ff = {k: v for k, v in sorted(tags.items()) if k.startswith("free_flying:")}
        ele = parse_ele(tags.get("ele"))
        rows[hg_class(tags)].append({
            "osm_type": el["type"], "osm_id": el["id"],
            "osm_url": "https://www.openstreetmap.org/%s/%d" % (el["type"], el["id"]),
            "name": tags.get("name", ""), "lat": round(c[0], 6), "lon": round(c[1], 6),
            "ele_m": ele, "country": "", "country_name": "", "country_name_ru": "", "site": tags.get("free_flying:site", ""),
            "hanggliding": tags.get("free_flying:hanggliding", ""),
            "paragliding": tags.get("free_flying:paragliding", ""),
            "site_orientation": tags.get("free_flying:site_orientation", tags.get("direction", "")),
            "tags": json.dumps(ff, ensure_ascii=False, sort_keys=True), "site_id": ""})
    return rows, dict(dropped), n_no_center


def _unit(lat, lon):
    la, lo = np.radians(lat), np.radians(lon)
    return np.stack([np.cos(la) * np.cos(lo), np.cos(la) * np.sin(lo), np.sin(la)], axis=1)


def cluster(rows, km=CLUSTER_KM):
    """Односвязная кластеризация по расстоянию (хорда). Возвращает метку кластера на каждую строку."""
    n = len(rows)
    if n == 0:
        return []
    xyz = _unit(np.array([r["lat"] for r in rows]), np.array([r["lon"] for r in rows]))
    chord = 2 * math.sin(km * 1000.0 / EARTH_R_M / 2)
    parent = list(range(n))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for a, b in sorted(cKDTree(xyz).query_pairs(chord)):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)
    return [find(i) for i in range(n)]


def build_sites(rows, km=CLUSTER_KM):
    """Присваивает site_id строкам, возвращает список мест (без relief_m/tile_hint)."""
    labels = cluster(rows, km)
    groups = {}
    for r, lab in zip(rows, labels):
        groups.setdefault(lab, []).append(r)
    sites = []
    for members in groups.values():
        withele = [m for m in members if m["ele_m"] is not None]
        if withele:
            top = sorted(withele, key=lambda m: (-m["ele_m"], m["lat"], m["lon"], m["osm_id"]))[0]
            clat, clon = top["lat"], top["lon"]
        else:
            clat = sum(m["lat"] for m in members) / len(members)
            clon = sum(m["lon"] for m in members) / len(members)
        names = [m["name"] for m in members if m["name"]]
        if withele and top["name"]:
            name = top["name"]
        elif names:
            name = sorted(Counter(names).items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
        else:
            name = ""
        cc = Counter(m["country"] for m in members if m["country"])
        country = sorted(cc.items(), key=lambda kv: (-kv[1], kv[0]))[0][0] if cc else ""
        ori = []
        for m in members:
            for v in _vals(m["site_orientation"]):
                if v not in ori:
                    ori.append(v)
        sites.append({
            "name": name, "lat": round(clat, 6), "lon": round(clon, 6), "country": country,
            "takeoffs": [{"osm_type": m["osm_type"], "osm_id": m["osm_id"]}
                         for m in sorted(members, key=lambda m: (m["osm_type"], m["osm_id"]))],
            "n_takeoffs": len(members),
            "ele_max_m": max((m["ele_m"] for m in withele), default=None),
            "site_orientation": ";".join(ori), "relief_m": None, "tile_hint": tile_hint(clat, clon),
            "_members": members})
    sites.sort(key=lambda s: (-s["n_takeoffs"], s["lat"], s["lon"]))
    for i, s in enumerate(sites):
        s["site_id"] = "hg_%04d" % i
        for m in s["_members"]:
            m["site_id"] = s["site_id"]
    return sites


def square_bbox(lat, lon, half_m=SQUARE_HALF_M):
    dlat = math.degrees(half_m / EARTH_R_M)
    dlon = math.degrees(half_m / (EARTH_R_M * max(math.cos(math.radians(lat)), 0.05)))
    return [round(lon - dlon, 5), round(lat - dlat, 5), round(lon + dlon, 5), round(lat + dlat, 5)]


def tile_hint(lat, lon):
    return {"source": "terrarium", "zoom": 12, "bbox": square_bbox(lat, lon)}


def quantiles(vals, qs=(0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0)):
    if not vals:
        return {}
    a = np.array(vals, dtype=float)
    return {("p%g" % (q * 100)): round(float(np.quantile(a, q)), 1) for q in qs}
