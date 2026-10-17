#!/usr/bin/env bash
# Кадры вулканического острова для проверки места (не для красоты), JPEG q88: сверху весь остров; с каждого старта по курсу и назад
# (кабина, --air-start=0,2); посадка-мишень с подлёта. Место bundled — игра читает res://data/locations/volcano_island сама;
# OSM bundled-места игра пока берёт из user://osm_tiles/v1 (VI-2 переведёт на osm/ места) — тайлы копируются в профиль.
# tools/terrain/volcano/shots.sh [выход [фильтр]]   (по умолчанию /home/greg/deltaplan/build/screenshots/volcano-island/VI-1;
#   фильтр — подстрока имени кадра, напр. east_cliffs: VI-5 снимал только новый старт)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-/home/greg/deltaplan/build/screenshots/volcano-island/VI-1}"
ONLY="${2:-}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$ROOT")}"
export DISPLAY="${DISPLAY:-:0}"
T="$XDG_DATA_HOME/Deltaplan/osm_tiles/v1"
mkdir -p "$T" && cp -r "$ROOT"/data/locations/volcano_island/osm/. "$T/"
TMP="$(mktemp -d)"
cp "$ROOT/project.godot" "$TMP/project.godot.bak"
trap 'cmp -s "$ROOT/project.godot" "$TMP/project.godot.bak" || cp "$TMP/project.godot.bak" "$ROOT/project.godot"; rm -rf "$TMP"' EXIT
mkdir -p "$OUT"
LOC=volcano_island
WIND="--wind=6 --from=110 --hour=12 --bots=0"
top() {   # сверху: terrain_preview
  local id="$1"; shift
  [[ -z "$ONLY" || "$id" == *"$ONLY"* ]] || return 0
  (cd "$ROOT" && timeout 240 godot --path . --audio-driver Dummy --resolution 1920x1080 \
    res://scenes/terrain/terrain_preview.tscn -- --location=$LOC "$@" --shot="$TMP/$id.png") > "$TMP/$id.log" 2>&1
  grep -q "Скриншот" "$TMP/$id.log" && echo "$id ok" || { echo "$id FAIL"; tail -5 "$TMP/$id.log"; }
}
shot() {  # из игры: кабина на старте
  local id="$1"; shift
  [[ -z "$ONLY" || "$id" == *"$ONLY"* ]] || return 0
  (cd "$ROOT" && timeout 300 godot --path . --audio-driver Dummy --resolution 1920x1080 -- --autostart --location=$LOC $WIND \
    --camera=cockpit --fov=75 --no-overlay --time=6 "$@" --screenshot="$TMP/$id.png") > "$TMP/$id.log" 2>&1
  [ -s "$TMP/$id.png" ] && echo "$id ok" || { echo "$id FAIL"; tail -5 "$TMP/$id.log"; }
}
top 00_top --pos=1000,22000,22000 --look=1000,0,3500 --no-haze
shot 01_east_cliffs --site=east_cliffs --air-start=0,2 --look=0,-6
shot 02_east_cliffs_back --site=east_cliffs --air-start=0,2 --look=180,-4
shot 03_crater_ridge --site=crater_ridge --air-start=0,2 --look=0,-6
shot 04_crater_ridge_back --site=crater_ridge --air-start=0,2 --look=180,-4
shot 05_plateau_landing --site=plateau_landing --air-start=0,2 --look=0,-8
shot 06_plateau_landing_back --site=plateau_landing --air-start=0,2 --look=180,-4
shot 07_landing_target_approach --site=plateau_landing --air-start=0,40 --look=0,-12
"$HERE/.venv/bin/python" - "$TMP" "$OUT" <<'PY'
import sys, glob, os
from PIL import Image
tmp, out = sys.argv[1], sys.argv[2]
for p in sorted(glob.glob(os.path.join(tmp, "*.png"))):
    q = os.path.join(out, os.path.basename(p)[:-4] + ".jpg")
    Image.open(p).convert("RGB").save(q, quality=88)
    print("→", q)
PY
