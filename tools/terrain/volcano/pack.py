"""Копия собранного места из профиля в data/locations/volcano_island/ (VI-К1): meta.json, *.webp, built_patches.json, surface.json,
osm_tiles.json, build.json (без location.json, *.import, *.remap, detail_raw.webp); поля location/key → volcano_island;
тайлы OSM со статусом ok → osm/<j>/<i>.dpt.   pack.py <профиль/Deltaplan> <ключ> <папка назначения>"""
import json
import shutil
import sys
from pathlib import Path

prof, key, dst = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
src = prof / "locations" / key
if not (src / "build.json").exists():
    raise SystemExit(f"нет {src}/build.json")
b = json.loads((src / "build.json").read_text())
if not b.get("complete") or b.get("missing"):
    raise SystemExit(f"сборка неполная: {b.get('missing')}")
shutil.rmtree(dst, ignore_errors=True)
dst.mkdir(parents=True)
for f in sorted(src.iterdir()):
    if f.name in ("location.json", "detail_raw.webp") or f.suffix in (".import", ".remap"):
        continue
    if f.suffix not in (".json", ".webp"):
        continue
    shutil.copy2(f, dst / f.name)
for name, field in (("meta.json", "location"), ("build.json", "key")):
    d = json.loads((dst / name).read_text())
    d[field] = "volcano_island"
    (dst / name).write_text(json.dumps(d, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
tiles = json.loads((dst / "osm_tiles.json").read_text())["tiles"]
n = 0
for j, i, st in tiles:
    if st == "ok":
        t = dst / "osm" / str(j) / f"{i}.dpt"
        t.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(prof / "osm_tiles/v1" / str(j) / f"{i}.dpt", t)
        n += 1
    elif st != "none":
        raise SystemExit(f"тайл {j}/{i}: статус {st} (в bundled-месте допустимы ok и none)")
print(f"{dst}: {len(list(dst.iterdir()))} файлов, тайлов OSM {n}")
