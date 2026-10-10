"""Таблица тайлов 100×100 км из results/tiles_*.json (Markdown)."""
import json
from pathlib import Path

R = Path(__file__).parent / "results"
print("| Место | Тайл | Всего, Б | Б/км² | дороги | track | ж/д | маска озёр | посёлки | обрывы | прочее |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for f in sorted(R.glob("tiles_*.json")):
    r = json.loads(f.read_text())
    b = r["build"]
    for nm, t in sorted(r["tiles"].items()):
        s = t["streams_zstd"]
        other = t["total_zstd"] - s["roads_main"] - s["roads_tp"] - s["rail"] - t["lake_mask_zstd"] \
            - s["places"] - s["cliffs"]
        print(f"| {r['place']} | {nm[5:]} | {t['total_zstd']} | {t['bytes_per_km2']} | {s['roads_main']} "
              f"| {s['roads_tp']} | {s['rail']} | {t['lake_mask_zstd']} | {s['places']} | {s['cliffs']} "
              f"| {other} |")
    print(f"<!-- {r['place']}: parse {b['t_parse_s']} c, mask+write {b['t_mask_write_s']} c, "
          f"maxrss {b['maxrss_MB']} MB -->")
