#!/usr/bin/env bash
# VI-К1: сборка данных вулканического острова обычным сборщиком (LocationBuilder) во временном профиле Godot → data/locations/volcano_island/.
# Нужна сеть (Copernicus GLO-30, Terrarium, ESA WorldCover, OSM-тайлы). Рельеф не правится.
#   tools/terrain/volcano/build.sh [--from ПРОФИЛЬ]   — --from: взять уже собранное место из профиля (XDG_DATA_HOME) без сети
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
KEY="pt_-27.100_-109.350"
DST="$ROOT/data/locations/volcano_island"
FROM=""
[ "${1:-}" = "--from" ] && FROM="$2"
if [ -z "$FROM" ]; then
  FROM="$(mktemp -d)"
  cp "$ROOT/project.godot" "$FROM/project.godot.bak"
  (cd "$ROOT" && XDG_DATA_HOME="$FROM" godot --headless --path . -s res://tools/terrain/build_location.gd -- --lat -27.10 --lon -109.35) \
    | tee "$FROM/build.log" | tail -12
  cmp -s "$ROOT/project.godot" "$FROM/project.godot.bak" || cp "$FROM/project.godot.bak" "$ROOT/project.godot"
fi
exec python3 "$HERE/pack.py" "$FROM/Deltaplan" "$KEY" "$DST"
