"""Каталог мест дельтаплана из OSM (S6). Стадии: fetch (сеть, кеш) → build (детерминированно по кешу).

    ../corpus/.venv/bin/python build.py fetch [--refresh]   # Overpass по тайлам мира → кеш
    ../corpus/.venv/bin/python build.py countries           # страна каждого старта (is_in) → кеш
    ../corpus/.venv/bin/python build.py relief              # тайлы Terrarium z9 → кеш
    ../corpus/.venv/bin/python build.py build               # sites.json, takeoffs.csv, unclear.csv, summary.*  (без сети)
    ../corpus/.venv/bin/python build.py all
"""
import csv
import json
import math
import sys
from pathlib import Path

import numpy as np

import catalog

HERE = Path(__file__).resolve().parent
RELIEF_Z = 9


def load_rows():
    import fetch
    els = fetch.fetch_takeoffs()
    return catalog.select(els)


def cmd_countries():
    import fetch
    rows, _, _ = load_rows()
    pts = [(r["lat"], r["lon"]) for k in ("hg", "unclear") for r in rows[k]]
    res, n = fetch.countries(pts)
    print("стартов-точек", len(res), "новых запросов", n)


def tile_xy(lat, lon, z):
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    lr = math.radians(lat)
    y = (1 - math.asinh(math.tan(lr)) / math.pi) / 2 * n
    return x, y


def relief_for(site, tilecache):
    """Перепад (max−min) высот Terrarium z9 в квадрате ±20 км: пиксели, центры которых внутри bbox."""
    import fetch
    z = RELIEF_Z
    w, s, e, n = catalog.square_bbox(site["lat"], site["lon"])
    x0, y1 = tile_xy(s, w, z)
    x1, y0 = tile_xy(n, e, z)
    vals = []
    for ty in range(int(math.floor(y0)), int(math.floor(y1)) + 1):
        for tx in range(int(math.floor(x0)), int(math.floor(x1)) + 1):
            key = (tx % 2 ** z, ty)
            if key not in tilecache:
                tilecache[key] = fetch.terrarium_tile(z, key[0], key[1])
            t = tilecache[key]
            if t is None:
                continue
            px0 = max(0, int(math.ceil((x0 - tx) * 256 - 0.5)))
            px1 = min(255, int(math.floor((x1 - tx) * 256 - 0.5)))
            py0 = max(0, int(math.ceil((y0 - ty) * 256 - 0.5)))
            py1 = min(255, int(math.floor((y1 - ty) * 256 - 0.5)))
            if px1 >= px0 and py1 >= py0:
                vals.append(t[py0:py1 + 1, px0:px1 + 1].ravel())
    if not vals:
        return None
    v = np.concatenate(vals)
    return float(v.max() - v.min())


def cmd_relief():
    rows, _, _ = load_rows()
    sites = catalog.build_sites(rows["hg"])
    cache = {}
    out = {}
    for i, s in enumerate(sites):
        out[s["site_id"]] = relief_for(s, cache)
        if i % 50 == 0:
            print("relief", i, "/", len(sites), flush=True)
    import fetch
    (fetch.CACHE / "relief.json").write_text(json.dumps(out, sort_keys=True))


def write_csv(path, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=catalog.CSV_COLUMNS, lineterminator="\n")
        w.writeheader()
        for r in rows:
            r = dict(r)
            r["ele_m"] = "" if r["ele_m"] is None else ("%g" % r["ele_m"])
            r["lat"] = "%.6f" % r["lat"]
            r["lon"] = "%.6f" % r["lon"]
            w.writerow({k: r[k] for k in catalog.CSV_COLUMNS})


def apply_countries(rows, cmap, names):
    for lst in rows.values():
        for r in lst:
            r["country"] = cmap.get("%.5f,%.5f" % (round(r["lat"], 5), round(r["lon"], 5)), "")
            en, ru = names.get(r["country"], ["", ""])
            r["country_name"], r["country_name_ru"] = en, ru


def cmd_build(out=HERE, cache=None):
    import fetch
    cache = Path(cache or fetch.CACHE)
    els = fetch.fetch_takeoffs()
    rows, dropped, n_no_center = catalog.select(els)
    cmap = {}
    for p in sorted((cache / "country").glob("*.json")):
        cmap.update(json.loads(p.read_text()))
    apply_countries(rows, cmap, fetch.country_names())
    sites = catalog.build_sites(rows["hg"])
    rel_p = cache / "relief.json"
    relief = json.loads(rel_p.read_text()) if rel_p.exists() else {}
    for s in sites:
        s["relief_m"] = None if relief.get(s["site_id"]) is None else round(relief[s["site_id"]], 1)
    write_csv(out / "takeoffs.csv", rows["hg"])
    write_csv(out / "unclear.csv", rows["unclear"])
    write_csv(out / "paraglide_only.csv", rows["paraglide_only"] + rows["hg_discouraged"])
    pub = [{k: v for k, v in s.items() if not k.startswith("_")} for s in sites]
    cols = ["site_id"] + [k for k in pub[0] if k != "site_id"] if pub else []
    pub = [{k: s[k] for k in cols} for s in pub]
    (out / "sites.json").write_text(json.dumps(pub, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    game = [{"id": "%s/%d" % (r["osm_type"], r["osm_id"]), "name": r["name"], "lat": r["lat"], "lon": r["lon"],
             "country": r["country"], "ele": r["ele_m"], "orientation": r["site_orientation"] or None}
            for r in rows["hg"]]
    (out / "takeoffs_game.json").write_text(json.dumps(game, ensure_ascii=False, separators=(",", ":")) + "\n",
                                            encoding="utf-8")
    meta = json.loads((cache / "fetch_meta.json").read_text())
    from collections import Counter
    cnt = Counter(s["country"] or "?" for s in sites)
    cnt_t = Counter(r["country"] or "?" for r in rows["hg"])
    reliefs = [s["relief_m"] for s in sites if s["relief_m"] is not None]
    hist, edges = np.histogram(reliefs, bins=[0, 250, 500, 750, 1000, 1500, 2000, 3000, 6000]) if reliefs else ([], [])
    summary = {
        "fetch_date_utc": meta["date_utc"], "overpass_body": meta["overpass_body"],
        "overpass_requests": {"takeoffs_world": meta["requests_takeoffs"],
                              "country_batches": len(list((cache / "country").glob("*.json")))},
        "n_elements_raw": len(els),
        "n_takeoffs_hg": len(rows["hg"]), "n_unclear": len(rows["unclear"]),
        "n_paraglide_only": len(rows["paraglide_only"]), "n_hg_discouraged": len(rows["hg_discouraged"]),
        "n_dropped_by_kind": dropped, "n_takeoff_without_geometry": n_no_center,
        "n_sites": len(sites),
        "game_extract_n": len(game), "game_extract_bytes": (out / "takeoffs_game.json").stat().st_size,
        "sites_by_n_takeoffs": {"1": sum(s["n_takeoffs"] == 1 for s in sites),
                                "2-5": sum(2 <= s["n_takeoffs"] <= 5 for s in sites),
                                ">5": sum(s["n_takeoffs"] > 5 for s in sites)},
        "by_country": dict(sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0]))),
        "takeoffs_by_country": dict(sorted(cnt_t.items(), key=lambda kv: (-kv[1], kv[0]))),
        "n_orientation_known": sum(bool(s["site_orientation"]) for s in sites),
        "n_ele_known": sum(s["ele_max_m"] is not None for s in sites),
        "relief_m_quantiles": catalog.quantiles(reliefs),
        "relief_m_hist": {"edges": [int(e) for e in edges], "counts": [int(h) for h in hist]},
        "relief_n_missing": len(sites) - len(reliefs),
        "relief_source": "Terrarium z%d, max-min по пикселям в квадрате +-20 км" % RELIEF_Z,
    }
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    top = list(summary["by_country"].items())[:15]
    q = summary["relief_m_quantiles"]
    md = ["# Каталог мест дельтаплана из OSM — сводка", "",
          "Выгрузка Overpass: %s. © OpenStreetMap contributors, ODbL." % meta["date_utc"], "",
          "| | число |", "|---|---|",
          "| старты дельтаплана (hanggliding=yes или rigid=yes) — `takeoffs.csv` | %d |" % summary["n_takeoffs_hg"],
          "| старты без тега дельтаплана и параплана — `unclear.csv` | %d |" % summary["n_unclear"],
          "| только параплан / hg не рекомендован — `paraglide_only.csv` | %d |" % (summary["n_paraglide_only"] + summary["n_hg_discouraged"]),
          "| выжимка для игры `takeoffs_game.json` | %d стартов, %d байт |" % (len(game), summary["game_extract_bytes"]),
          "| места (кластеры < 10 км) — `sites.json` | %d |" % summary["n_sites"], "",
          "Отброшено (не старты), по видам: %s." % json.dumps(dropped, ensure_ascii=False), "",
          "## Места по странам (топ-15)", "", "| страна | мест |", "|---|---|"]
    md += ["| %s | %d |" % kv for kv in top]
    md += ["", "## Перепад в квадрате 40 × 40 км, м (%s)" % summary["relief_source"], "",
           "Квантили: %s. Без значения: %d." % (json.dumps(q), summary["relief_n_missing"])]
    (out / "summary.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print(json.dumps({k: summary[k] for k in ("n_takeoffs_hg", "n_unclear", "n_paraglide_only", "n_sites")}))


if __name__ == "__main__":
    c = sys.argv[1] if len(sys.argv) > 1 else "all"
    if "--refresh" in sys.argv:
        import fetch
        fetch.fetch_takeoffs(refresh=True)
    if c in ("fetch", "all"):
        import fetch
        fetch.fetch_takeoffs()
    if c in ("countries", "all"):
        cmd_countries()
    if c in ("relief", "all"):
        cmd_relief()
    if c in ("build", "all"):
        cmd_build()
