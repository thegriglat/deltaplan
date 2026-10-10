#!/usr/bin/env python3
"""Оценка размера планеты по нашим тайлам: цена объекта (Б, zstd 19 по потокам) × мировые числа taginfo.

    python3 estimate_planet.py [метка=]stats.json ... [--out estimate_planet.json] [--taginfo FILE]
                               [--tiles-lo 400000 --tiles-hi 500000] [--overhead-per-tile 34]

Как `tools/research/osm_pack/report20.py` (§9.5 docs/plan/osm_vector_pack.md): цена = сумма zstd потока /
сумма объектов по тайлам файла; мировое число — из `taginfo_counts.json` (те же формулы WORLD). Метка места
берётся из имени файла (slovenia|almaty), иначе из `метка=`. Вилка — min..max по местам.
Состав = потоки O6: roads (major+minor вместе), track, buildings >= 50 м2, потоки для пилота, names.
Отличия от report20 (O6 беднее эталона): нет раздельных major/minor дорог (если в сводке есть не-контрактный
поток roads_major — используется, иначе одна цена на все дороги) и нет числа всех домов (доля >= 50 м2
берётся из эталона места: n_ge50 / n_buildings; для неизвестного места — среднее по двум эталонам).
Накладные на тайл: заголовок O2 16 Б + кадр zstd (магия 4 + дескриптор 1..10 + заголовок блока 3 + контрольная
сумма 4 ≈ 18 Б) = 34 Б по умолчанию, × 0,4–0,5 млн тайлов (суша 149 млн км2 / 400 км2 ≈ 0,37 млн + береговые).
Применимость: оценка, не измерение: цена объекта зависит от детальности картографирования места.
"""
import argparse
import json
import sys
from pathlib import Path

DEFAULT_RES = Path(__file__).resolve().parents[1] / "research" / "osm_pack" / "results"
MAJOR = ("motorway", "trunk", "primary", "secondary", "tertiary", "motorway_link", "trunk_link", "primary_link",
         "secondary_link", "tertiary_link")
MINOR = ("unclassified", "residential", "living_street", "road")


def world_counts(ti, bldg_frac):
    """мировые числа по потокам O6 (формулы — как WORLD в report20.py)."""
    def tag(kv, k="ways"):
        return ti["tags"][kv].get(k, 0)

    def tagall(kv):
        return ti["tags"][kv].get("all", 0)
    bldg = ti["keys"]["building"]["ways"] + ti["keys"]["building"]["relations"] - tagall("building=no")
    w = {
        "roads_major": sum(tag(f"highway={c}") for c in MAJOR),
        "roads_minor": sum(tag(f"highway={c}") for c in MINOR),
        "track": tag("highway=track"),
        "buildings": bldg * bldg_frac,
        "powerline": tag("power=line") + tag("power=minor_line"),
        "power_tower": tag("power=tower", "nodes"),
        "aerialway": sum(tag(k) for k in ti["tags"] if k.startswith("aerialway=")),
        "aeroway": tagall("aeroway=aerodrome") + tagall("aeroway=airstrip") + tagall("aeroway=helipad")
        + tag("aeroway=runway"),
        "vertical": tag("man_made=mast", "nodes") + tag("man_made=tower", "nodes")
        + tag("man_made=chimney", "nodes") + tag("generator:source=wind", "nodes"),
        "rail": tag("railway=rail") + tag("railway=narrow_gauge"),
        "peak": tag("natural=peak", "nodes"),
        "pass": tag("natural=saddle", "nodes") + tag("mountain_pass=yes", "nodes"),
        "river": tag("waterway=river"),
        "canal": tag("waterway=canal"),
    }
    w["roads"] = w["roads_major"] + w["roads_minor"]
    w["names"] = w["peak"] + w["pass"]    # масштабируется долей имён места
    w["_buildings_all"] = bldg
    return w


def ref_bldg_frac(place, res_dir):
    def frac(tiles):
        n = sum(t["n_buildings"] for t in tiles.values())
        return sum(t["n_ge"]["ge50"] for t in tiles.values()) / n
    fs = {}
    fs["slovenia"] = frac(json.loads((res_dir / "tiles20_slovenia.json").read_text())["tiles"])
    fs["almaty"] = frac(json.loads((res_dir / "tiles20_almaty.json").read_text())["tiles"])
    return fs.get(place, sum(fs.values()) / 2), place in fs


def place_of(path, label, stats=None):
    if label:
        return label
    if stats and stats.get("place"):
        return stats["place"]
    n = Path(path).name.lower()
    for p in ("slovenia", "almaty"):
        if p in n:
            return p
    return Path(path).stem


def estimate_place(stats, ti, frac):
    tot = stats["totals"]
    for n, v in tot.items():
        if "zstd" not in v:
            raise SystemExit(f"в сводке нет zstd у потока {n}: нужен osmtiles stats --zstd-per-stream")
    W = world_counts(ti, frac)
    unit, comp = {}, {}

    def price(s):
        t = tot.get(s)
        return None if not t or not t.get("count") else t["zstd"] / t["count"]
    split = "roads_major" in tot and "roads" in tot and tot["roads"]["count"] > tot["roads_major"]["count"] > 0
    if split:
        rm, r = tot["roads_major"], tot["roads"]
        unit["roads_major"] = rm["zstd"] / rm["count"]
        unit["roads_minor"] = (r["zstd"] - rm["zstd"]) / (r["count"] - rm["count"])
        comp["roads"] = unit["roads_major"] * W["roads_major"] + unit["roads_minor"] * W["roads_minor"]
    else:
        unit["roads"] = price("roads")
        comp["roads"] = (unit["roads"] or 0) * W["roads"]
    for s in ("track", "buildings", "powerline", "power_tower", "aerialway", "aeroway", "vertical", "rail",
              "peak", "pass", "river", "canal"):
        unit[s] = price(s)
        comp[s] = (unit[s] or 0) * W[s]
    pp = tot.get("peak", {}).get("count", 0) + tot.get("pass", {}).get("count", 0)
    nm = tot.get("names", {}).get("count", 0)
    unit["names"] = price("names")
    unit["names_frac"] = nm / pp if pp else 0.0
    comp["names"] = (unit["names"] or 0) * unit["names_frac"] * W["names"]
    missing = sorted(s for s, v in unit.items() if v is None)
    return {"n_tiles": stats.get("n_tiles", len(stats.get("tiles", {}))), "bldg_ge50_frac": round(frac, 4),
            "roads_split": split, "unit_B": {k: (None if v is None else round(v, 3)) for k, v in unit.items()},
            "world_B": {k: round(v) for k, v in comp.items()}, "world_GB": round(sum(comp.values()) / 1e9, 3),
            "streams_without_objects": missing,
            "file_overhead_B_per_tile_measured": _overhead(stats)}


def _overhead(stats):
    fb, n = stats.get("file_bytes_total"), stats.get("n_tiles")
    zs = [v.get("zstd", 0) for v in stats["totals"].values()]
    if fb is None or not n or stats.get("synthetic_from_reference"):
        return None
    return round((fb - sum(zs)) / n, 2)   # < 0 — общий кадр сжал лучше, чем потоки по отдельности


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stats", nargs="+")
    ap.add_argument("--taginfo", default=str(DEFAULT_RES / "taginfo_counts.json"))
    ap.add_argument("--tiles-lo", type=float, default=400_000)
    ap.add_argument("--tiles-hi", type=float, default=500_000)
    ap.add_argument("--overhead-per-tile", type=float, default=34.0)
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    ti = json.loads(Path(a.taginfo).read_text())
    res_dir = Path(a.taginfo).parent
    places, first = {}, None
    for arg in a.stats:
        label, _, path = arg.rpartition("=") if "=" in arg else ("", "", arg)
        first = first or path
        st = json.loads(Path(path).read_text())
        name = place_of(path, label, st)
        frac, known = ref_bldg_frac(name, res_dir)
        e = estimate_place(st, ti, frac)
        e["bldg_frac_known_place"] = known
        places[name] = e
    ov_lo = a.tiles_lo * a.overhead_per_tile / 1e9
    ov_hi = a.tiles_hi * a.overhead_per_tile / 1e9
    gb = [p["world_GB"] for p in places.values()]
    lo, hi = min(gb) + ov_lo, max(gb) + ov_hi
    out = {"taginfo_date": ti.get("date"), "places": places,
           "overhead": {"per_tile_B": a.overhead_per_tile, "tiles": [a.tiles_lo, a.tiles_hi],
                        "GB": [round(ov_lo, 4), round(ov_hi, 4)]},
           "objects_GB": [round(min(gb), 3), round(max(gb), 3)], "planet_GB": [round(lo, 2), round(hi, 2)],
           "budget_GB": 10, "fits_budget": hi <= 10}
    path = Path(a.out) if a.out else Path(first).resolve().parent / "estimate_planet.json"
    path.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    for n, p in places.items():
        print(f"{n}: объекты {p['world_GB']:.2f} ГБ (тайлов {p['n_tiles']}, доля домов ≥50 м² {p['bldg_ge50_frac']})")
    print(f"накладные: {ov_lo*1000:.0f}–{ov_hi*1000:.0f} МБ")
    print(f"планета: {lo:.1f}–{hi:.1f} ГБ ({'укладывается' if out['fits_budget'] else 'НЕ укладывается'} в 10 ГБ); "
          f"json: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
