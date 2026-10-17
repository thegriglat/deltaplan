#!/usr/bin/env bash
# Кадры учебного острова для проверки мест (не для красоты): сверху весь остров и со стартов, JPEG q88.
# Место берётся из кеша своего профиля: папка data/locations/training_island копируется в
# user://locations/training_island (встроенное место с полным build.json грузится без сети).
# tools/terrain/island/shots.sh [выход]   (по умолчанию /home/greg/deltaplan/build/screenshots/training-island/TI-1)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-/home/greg/deltaplan/build/screenshots/training-island/TI-1}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$ROOT")}"
export DISPLAY="${DISPLAY:-:0}"
U="$XDG_DATA_HOME/Deltaplan/locations/training_island"
rm -rf "$U" && mkdir -p "$U" && cp "$ROOT"/data/locations/training_island/*.json "$ROOT"/data/locations/training_island/*.webp "$U/"
TMP="$(mktemp -d)"
cp "$ROOT/project.godot" "$TMP/project.godot.bak"
trap 'cmp -s "$ROOT/project.godot" "$TMP/project.godot.bak" || cp "$TMP/project.godot.bak" "$ROOT/project.godot"; rm -rf "$TMP"' EXIT
mkdir -p "$OUT"
shot() {
  local id="$1"; shift
  (cd "$ROOT" && timeout 180 godot --path . --audio-driver Dummy --resolution 1920x1080 \
    res://scenes/terrain/terrain_preview.tscn -- --location=training_island "$@" --shot="$TMP/$id.png") \
    > "$TMP/$id.log" 2>&1
  grep -q "Скриншот" "$TMP/$id.log" && echo "$id ok" || { echo "$id FAIL"; tail -5 "$TMP/$id.log"; }
}
shot 00_top --pos=1000,9000,12000 --look=0,0,-300 --no-haze
shot 01_ridge_west --site=ridge_west --agl=2 --clearings
shot 02_thermal_plain --site=thermal_plain --agl=2 --clearings
shot 03_landing_hill --site=landing_hill --agl=2 --clearings
shot 04_lee_bowl --site=lee_bowl --agl=2 --clearings
shot 05_lee_bowl_back --site=lee_bowl --agl=2 --yaw=180 --clearings
shot 06_landing_target --landing --agl=30 --clearings
"$HERE/.venv/bin/python" - "$TMP" "$OUT" <<'PY'
import sys, glob, os
from PIL import Image
tmp, out = sys.argv[1], sys.argv[2]
for p in sorted(glob.glob(os.path.join(tmp, "*.png"))):
    Image.open(p).convert("RGB").save(os.path.join(out, os.path.basename(p)[:-4] + ".jpg"), quality=88)
    print("→", os.path.join(out, os.path.basename(p)[:-4] + ".jpg"))
PY
