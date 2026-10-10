"""Итоги §9: единичные цены по Словении/Алматы × мировые количества (taginfo), пресеты, загрузка 9 тайлов.
    python -I report20.py   (читает results/tiles20_slovenia.json, pilot20_slovenia.json, tiles20_almaty.json,
                             taginfo_counts.json; пишет results/report20.json)
Оценка на планету — ОЦЕНКА: цена за объект зависит от детальности картографирования места."""
import json
import sys
from pathlib import Path
from statistics import median

sys.path.insert(0, str(Path(__file__).parent))
R = Path(__file__).parent / "results"
sl = json.loads((R / "tiles20_slovenia.json").read_text())
slp = json.loads((R / "pilot20_slovenia.json").read_text())
al = json.loads((R / "tiles20_almaty.json").read_text())
ti = json.loads((R / "taginfo_counts.json").read_text())

PSUB = ["powerline", "tower", "aerialway", "aeroway", "vertical", "rail", "peak", "pass", "river", "canal",
        "river_named", "comm", "names"]
BSUB = ["roads", "roads_major", "track", "bpoly", "brect", "brect_ge50", "brect_ge100", "brect_ge200",
        "bpoly_ge50", "bpoly_ge100", "bpoly_ge200"]


def tag(kv, k="ways"):
    return ti["tags"][kv].get(k, 0)


def tagall(kv):
    return ti["tags"][kv].get("all", 0)


WORLD = {
    "bldg": ti["keys"]["building"]["ways"] + ti["keys"]["building"]["relations"] - tagall("building=no"),
    "roads_major": sum(tag(f"highway={c}") for c in ("motorway", "trunk", "primary", "secondary", "tertiary",
                                                       "motorway_link", "trunk_link", "primary_link",
                                                       "secondary_link", "tertiary_link")),
    "roads_minor": sum(tag(f"highway={c}") for c in ("unclassified", "residential", "living_street", "road")),
    "track": tag("highway=track"),
    "powerline": tag("power=line") + tag("power=minor_line"),
    "tower": tag("power=tower", "nodes"),
    "aerialway": sum(tag(k) for k in ti["tags"] if k.startswith("aerialway=")),
    "aeroway": tagall("aeroway=aerodrome") + tagall("aeroway=airstrip") + tagall("aeroway=helipad") + tag("aeroway=runway"),
    "vertical": tag("man_made=mast", "nodes") + tag("man_made=tower", "nodes") + tag("man_made=chimney", "nodes")
    + tag("generator:source=wind", "nodes"),
    "comm": tag("tower:type=communication", "nodes"),
    "rail": tag("railway=rail") + tag("railway=narrow_gauge"),
    "peak": tag("natural=peak", "nodes"),
    "pass": tag("natural=saddle", "nodes") + tag("mountain_pass=yes", "nodes"),
    "river": tag("waterway=river"),
    "canal": tag("waterway=canal"),
}


def agg(tiles, pilot, keys):
    """суммы байт по потокам и число объектов по набору тайлов (ключи 'j,i')."""
    b = {s: 0 for s in BSUB}
    cnt = {"bldg": 0, "ge50": 0, "ge100": 0, "ge200": 0, "parts_roads": 0, "parts_major": 0, "parts_track": 0,
           "km_roads": 0.0, "km_major": 0.0, "km_track": 0.0}
    pz = {s: 0 for s in PSUB}
    pc = {s: 0 for s in PSUB}
    for k in keys:
        t = tiles.get(k)
        if t:
            for s in BSUB:
                b[s] += t["streams_zstd"].get(s, 0)
            cnt["bldg"] += t["n_buildings"]
            for th in ("ge50", "ge100", "ge200"):
                cnt[th] += t.get("n_ge", {}).get(th, 0)
            cnt["parts_roads"] += t["n_road_parts"]["roads"]
            cnt["parts_major"] += t["n_road_parts"].get("roads_major", 0)
            cnt["parts_track"] += t["n_road_parts"]["track"]
            cnt["km_roads"] += t["len_km"]["roads"]
            cnt["km_major"] += t["len_km"].get("roads_major", 0)
            cnt["km_track"] += t["len_km"]["track"]
        q = pilot.get(k)
        if q:
            for s in PSUB:
                pz[s] += q["zstd"].get(s, 0)
                pc[s] += q["count"].get(s, 0)
    return b, cnt, pz, pc


def unit(b, cnt, pz, pc):
    """цена за объект, Б."""
    u = {}
    u["roads_major"] = b["roads_major"] / max(1, cnt["parts_major"])
    u["roads_minor"] = (b["roads"] - b["roads_major"]) / max(1, cnt["parts_roads"] - cnt["parts_major"])
    u["track"] = b["track"] / max(1, cnt["parts_track"])
    for s in ("brect", "bpoly"):
        u[s] = b[s] / max(1, cnt["bldg"])
    for th in ("50", "100", "200"):
        u["brect_ge" + th] = b["brect_ge" + th] / max(1, cnt["ge" + th])
        u["frac_ge" + th] = cnt["ge" + th] / max(1, cnt["bldg"])
    for s in PSUB:
        u[s] = pz[s] / max(1, pc[s])
    u["river_named_frac"] = pc["river_named"] / max(1, pc["river"])
    u["names_frac"] = pc["names"] / max(1, pc["peak"] + pc["pass"])
    u["comm_frac"] = pc["comm"] / max(1, pc["vertical"])
    return u


def components(u, W, p):
    """байт на планету по компонентам при долях ge (p = пороги)."""
    c = {}
    c["roads_major"] = u["roads_major"] * W["roads_major"]
    c["roads_minor"] = u["roads_minor"] * W["roads_minor"]
    c["track"] = u["track"] * W["track"]
    for th in ("50", "100", "200"):
        c["brect_ge" + th] = u["brect_ge" + th] * u["frac_ge" + th] * W["bldg"]
    c["brect"] = u["brect"] * W["bldg"]
    c["bpoly"] = u["bpoly"] * W["bldg"]
    for s in ("powerline", "tower", "aerialway", "aeroway", "vertical", "rail", "peak", "pass", "canal", "river"):
        c[s] = u[s] * W[s]
    c["river_named"] = u["river_named"] * u["river_named_frac"] * W["river"]
    c["comm"] = u["comm"] * W["comm"]    # подмножество vertical
    c["names"] = u["names"] * u["names_frac"] * (W["peak"] + W["pass"])
    return c


PRESETS = {
    "A узнаваемо": ["roads_major", "brect_ge100", "peak", "pass", "names", "river_named", "canal", "powerline",
                    "aerialway", "aeroway", "vertical", "rail"],
    "B средне": ["roads_major", "roads_minor", "brect_ge50", "peak", "pass", "names", "river", "canal",
                 "powerline", "aerialway", "aeroway", "vertical", "rail"],
    "C детально": ["roads_major", "roads_minor", "track", "brect", "peak", "pass", "names", "river", "canal",
                   "powerline", "tower", "aerialway", "aeroway", "vertical", "rail"],
}


def tile_preset_bytes(tiles, pilot, k, parts):
    """байты тайла для пресета (parts — список компонентов)."""
    t = tiles.get(k)
    q = pilot.get(k)
    z = (t or {}).get("streams_zstd", {})
    pz = (q or {}).get("zstd", {})
    tot = 0
    for c in parts:
        if c == "roads_minor":
            tot += z.get("roads", 0) - z.get("roads_major", 0)
        elif c in z:
            tot += z[c]
        elif c in pz:
            tot += pz[c]
    return tot


def windows(tiles, side, inside_only, allowed=None):
    """3x3 окна по мировой сетке вокруг тайлов (соседи по полосам — через stage2.block); пустые тайлы = 0 байт."""
    from build_tiles20 import DLAT, Band
    from stage2 import block
    out = []
    for k in tiles:
        j, i = map(int, k.split(","))
        if inside_only and not tiles[k].get("inside"):
            continue
        bd = Band.get(j)
        ws = block(bd.lon0(i) + bd.dlon / 2, (j + .5) * DLAT, side // 2)
        ws = [f"{a},{b}" for a, b in ws]
        if len(ws) == side * side and (allowed is None or all(w in allowed for w in ws)):
            out.append(ws)
    return out


places = {}
sl_keys = list(sl["tiles"])
sl_in = [k for k in sl_keys if sl["tiles"][k].get("inside")]
al_keys = list(al["tiles"])
for name, tiles, pilot, keys in (("Slovenia", sl["tiles"], slp["tiles"], sl_keys),
                                 ("Almaty5x5", al["tiles"], al["pilot_tiles"], al_keys)):
    b, cnt, pz, pc = agg(tiles, pilot, keys)
    u = unit(b, cnt, pz, pc)
    comp = components(u, WORLD, None)
    P = {"unit_B": {k: round(v, 3) for k, v in u.items()}, "world_B": {k: round(v) for k, v in comp.items()},
         "presets": {}}
    # окна 3×3
    if name == "Slovenia":
        wins = windows(tiles, 3, True)
    else:
        from stage2 import block
        allowed = {f"{a},{b}" for a, b in block(76.89, 43.24, 2)}
        wins = windows({k: v for k, v in tiles.items() if k in allowed}, 3, False, allowed)
    for pn, parts in PRESETS.items():
        world = sum(comp[c] for c in parts)
        loads = [sum(tile_preset_bytes(tiles, pilot, k, parts) for k in w) for w in wins]
        pt = [tile_preset_bytes(tiles, pilot, k, parts) for k in keys if tiles[k].get("inside", True)]
        P["presets"][pn] = {"world_GB": round(world / 1e9, 2), "load9_median": median(loads), "load9_max": max(loads),
                            "n_windows": len(loads), "tile_median": median(pt), "tile_max": max(pt)}
    # доля байт домов < порога
    P["bldg_share_below"] = {th: round(1 - b["brect_ge" + th] / b["brect"], 3) for th in ("50", "100", "200")}
    P["bldg_count_share_below"] = {th: round(1 - cnt["ge" + th] / cnt["bldg"], 3) for th in ("50", "100", "200")}
    P["totals_B"] = b
    P["totals_pilot_B"] = pz
    P["counts"] = {**cnt, **{"pilot_" + k: v for k, v in pc.items()}}
    places[name] = P
out = {"world_counts": WORLD, "taginfo_date": ti["date"], "places": places}
(R / "report20.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
for n, P in places.items():
    print(n)
    for pn, v in P["presets"].items():
        print(" ", pn, v)
    print("  below", P["bldg_share_below"], P["bldg_count_share_below"])
    print("  world components GB", {k: round(v / 1e9, 3) for k, v in P["world_B"].items()})
