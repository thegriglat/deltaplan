#!/usr/bin/env bash
# OA-6: кадры игры на собранной точке (по умолчанию Альпы 47.05/11.0) — рельеф, реки, лес, OSM-объекты.
#   bash tools/shots/point_shots.sh [выход] [lat lon]    (по умолчанию /home/greg/deltaplan/build/screenshots/osm-any)
# Профиль — тот же build/point_cache_xdg, что у tools/terrain/check_point_cache.sh (место берётся из кеша,
# нет в кеше — соберётся с сетью). Нужен дисплей (DISPLAY=:0); GPU-замок не берём. Каждый кадр под timeout.
# Игра с окном переписывает project.godot — после запуска возвращаем.
set -uo pipefail
cd "$(dirname "$0")/../.."
out="${1:-/home/greg/deltaplan/build/screenshots/osm-any}"
lat="${2:-47.05}"
lon="${3:-11.0}"
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}" XDG_DATA_HOME="$PWD/build/point_cache_xdg"

shot() {  # shot <имя файла> <аргументы игры...>
  local f="$out/$1.png"
  shift
  echo "-- $f"
  timeout 400 godot --path . --audio-driver Dummy --resolution 1600x900 -- --autostart --autopilot \
    --latlon="$lat,$lon" --no-overlay "$@" "--screenshot=$f" 2>&1 | grep -E "^screenshot:|SCRIPT ERROR" || true
}

# вид: старт в воздухе <дистанция от старта>,<высота над рельефом>; --look рыскание,тангаж
shot "01 Рельеф, реки и лес с высоты" --air-start=1500,500 --camera=cockpit --look=0,-10 --time=6
shot "02 Лес и луга у точки" --air-start=300,150 --camera=cockpit --look=0,-22 --time=5
shot "03 Долина в стороне" --air-start=1500,500 --camera=cockpit --look=60,-12 --time=6
shot "04 Вид сзади над долиной" --air-start=1500,350 --camera=chase --time=6
git checkout -- project.godot 2>/dev/null
ls "$out"
