#!/usr/bin/env python3
"""Эталон §9 (tools/research/osm_pack/results) -> сводка O6 (osmtiles-stats/1) для самопроверки сверки.

    python3 ref_to_stats.py --ref slovenia|almaty [--perturb поток:поле:множитель]... [--with-roads-major]
                            [--ref-dir DIR] > stats.json

Соответствие (docs/contracts/osm-tiles.md, O6): roads/track <- n_road_parts, streams_raw|zstd, len_km;
buildings <- n_ge.ge50, brect_ge50; потоки для пилота <- pilot20_slovenia.json / pilot_tiles Алматы
(count|zstd; raw в эталоне нет и не выдумывается; power_tower <- tower).
file_bytes — СИНТЕТИКА (сумма zstd потоков тайла): в эталоне размера итогового файла нет.
--perturb умножает поле (count|raw|zstd|len_km) потока во всех тайлах; целые округляются с переносом
остатка по тайлам (сумма точна), потом итоги и file_bytes пересчитываются.
--with-roads-major добавляет НЕ-контрактный поток roads_major (для проверки estimate_planet).
"""
import argparse
import json
import sys
from pathlib import Path

DEFAULT_REF_DIR = Path(__file__).resolve().parents[1] / "research" / "osm_pack" / "results"
PILOT_MAP = {"powerline": "powerline", "tower": "power_tower", "aerialway": "aerialway", "aeroway": "aeroway",
             "vertical": "vertical", "rail": "rail", "peak": "peak", "pass": "pass", "river": "river",
             "canal": "canal", "names": "names"}
LINEAR = {"roads", "track", "powerline", "aerialway", "rail", "river", "canal"}


def load_ref(ref, ref_dir=None):
    """-> (tiles, inside): tiles {ключ: {поток: {count,[raw],zstd,[len_km]}}}, inside {ключ: bool}."""
    d = Path(ref_dir) if ref_dir else DEFAULT_REF_DIR
    if ref == "slovenia":
        base = json.loads((d / "tiles20_slovenia.json").read_text())["tiles"]
        pil = json.loads((d / "pilot20_slovenia.json").read_text())["tiles"]
    elif ref == "almaty":
        a = json.loads((d / "tiles20_almaty.json").read_text())
        base, pil = a["tiles"], a["pilot_tiles"]
    else:
        raise SystemExit(f"неизвестный --ref {ref}")
    tiles, inside = {}, {}
    for k, t in base.items():
        s = tiles.setdefault(k, {})
        for name, key in (("roads", "roads"), ("track", "track")):
            s[name] = {"count": t["n_road_parts"][key], "raw": t["streams_raw"][key],
                       "zstd": t["streams_zstd"][key], "len_km": t["len_km"][key]}
        s["buildings"] = {"count": t["n_ge"]["ge50"], "raw": t["streams_raw"]["brect_ge50"],
                          "zstd": t["streams_zstd"]["brect_ge50"]}
        s["roads_major"] = {"count": t["n_road_parts"].get("roads_major", 0),
                            "raw": t["streams_raw"].get("roads_major", 0),
                            "zstd": t["streams_zstd"].get("roads_major", 0)}
        inside[k] = t.get("inside", True)
    for k, q in pil.items():
        s = tiles.setdefault(k, {})
        for a, b in PILOT_MAP.items():
            s[b] = {"count": q["count"].get(a, 0), "zstd": q["zstd"].get(a, 0)}
        inside.setdefault(k, q.get("inside", True))
    return tiles, inside


def perturb(tiles, spec):
    stream, field, mult = spec.split(":")
    mult = float(mult)
    carry = 0.0
    for k in sorted(tiles):
        s = tiles[k].get(stream)
        if not s or field not in s:
            continue
        v = s[field] * mult
        if field == "len_km":
            s[field] = v
        else:
            v += carry
            r = round(v)
            carry = v - r
            s[field] = int(r)


def to_o6(tiles, with_major=False, place=None):
    out_tiles, totals = {}, {}
    for k, ss in tiles.items():
        ss = {n: dict(v) for n, v in ss.items() if n != "roads_major" or with_major}
        fb = 0
        for n, v in ss.items():
            fb += v.get("zstd", 0)
            tot = totals.setdefault(n, {})
            for f, x in v.items():
                tot[f] = tot.get(f, 0) + x
        out_tiles[k] = {"file_bytes": fb, "streams": ss}
    for n, v in totals.items():
        if "len_km" in v:
            v["len_km"] = round(v["len_km"], 6)
    return {"schema": "osmtiles-stats/1", "n_tiles": len(out_tiles),
            "file_bytes_total": sum(t["file_bytes"] for t in out_tiles.values()),
            "synthetic_from_reference": True, "place": place, "tiles": out_tiles, "totals": totals}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ref", required=True, choices=("slovenia", "almaty"))
    ap.add_argument("--perturb", action="append", default=[], metavar="поток:поле:множитель")
    ap.add_argument("--with-roads-major", action="store_true")
    ap.add_argument("--ref-dir")
    a = ap.parse_args(argv)
    tiles, _ = load_ref(a.ref, a.ref_dir)
    for p in a.perturb:
        perturb(tiles, p)
    json.dump(to_o6(tiles, a.with_roads_major, a.ref), sys.stdout, ensure_ascii=False, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
