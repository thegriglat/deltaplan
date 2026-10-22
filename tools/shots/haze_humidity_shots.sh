#!/usr/bin/env bash
# Кадры до/после модуля haze-humidity (карточка HH-10): закат из кабины и основание облаков днём.
# tools/shots/haze_humidity_shots.sh <корень_копии> <префикс> [выход]
#   корень_копии — копия игры (main для «до», ветка модуля для «после»); префикс — before_ | after_.
#   выход по умолчанию — /home/greg/deltaplan/build/screenshots/haze-humidity
# Кадры <префикс>sunset_<место>.jpg, <префикс>halo_<место>.jpg (HH-11, замер пятна sun_halo_measure.py) и <префикс>day_<место>.jpg, JPEG q88, 1920x1080.
# Условия (одни и те же для до и после): 15 июля (по умолчанию), --seed=7, --sky=partly, кабина,
#   синтетический пилот, без прибора.
#   Закат: --hour=20 + 40 с полёта при времени ×60 (минута за секунду; world.json → time.speed
#   берётся из временной правки профиля user://configs/world.json) = 20:40. Взгляд к солнцу:
#   рыскание = курс старта − азимут солнца (+ влево), тангаж = высота солнца; считается по тем
#   же формулам NOAA, что SunClock.solar_position.
#   День: --hour=12, старт в воздухе (--air-start: 300 м от старта, 300 м над рельефом; со склона
#   днём автопилот сразу падает), 20 с полёта, время ×1, взгляд 0,25 (вверх, на основание облаков).
# HALO_ONLY=1 — только кадры halo (HH-11).
# Профиль Godot — XDG_DATA_HOME копии (по умолчанию ~/.cache/dp-xdg/<имя папки копии>).
# Окну нужен настоящий дисплей (DISPLAY=:0); каждый запуск — под timeout 150 с.
set -euo pipefail
root="$(cd "${1:?корень копии}" && pwd)"
prefix="${2:?префикс: before_ | after_}"
out="${3:-/home/greg/deltaplan/build/screenshots/haze-humidity}"
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$root")}"
SEED=7
# место | старт | широта | долгота | пояс UTC+N | курс старта, °
places=(
  "altai|sinyukha_west|51.87|85.87|7|276"
  "askarovo|biyagoda_west|53.26|58.54|5|294"
)

cfg_dir="$XDG_DATA_HOME/Deltaplan/configs"
cfg="$cfg_dir/world.json"
mkdir -p "$cfg_dir"
backup=""
if [[ -f "$cfg" ]]; then backup="$(mktemp)"; cp "$cfg" "$backup"; fi
restore() {
  if [[ -n "$backup" ]]; then cp "$backup" "$cfg"; rm -f "$backup"; else rm -f "$cfg"; fi
}
trap restore EXIT

set_speed() { echo "{\"time\": {\"speed\": $1}}" > "$cfg"; }

# sun <широта> <долгота> <пояс> <часы> → "азимут высота" (15 июля, doy 196)
sun() {
  python3 - "$@" <<'PY'
import sys
from math import *
lat, lon, off, h = map(float, sys.argv[1:5])
doy = 196
g = 2 * pi / 365 * (doy - 1 + (h - 12) / 24)
d = (0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g)
     + 0.000907 * sin(2 * g) - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g))
e = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g)
              - 0.040849 * sin(2 * g))
s = h + (4 * lon - 60 * off + e) / 60
ha = radians(15 * (s - 12)); la = radians(lat)
el = asin(sin(la) * sin(d) + cos(la) * cos(d) * cos(ha))
az = atan2(sin(ha), cos(ha) * sin(la) - tan(d) * cos(la)) + pi
print("%.2f %.2f" % (degrees(az) % 360, degrees(el)))
PY
}

shot() {  # shot <файл.jpg> <аргументы игры...>
  local file="$1"; shift
  local png="${file%.jpg}.png"
  echo "-- $(basename "$file")"
  local try
  for try in 1 2 3; do  # окно иногда не получает экран (NO GRAB) — повтор
    rm -f "$png"
    (cd "$root" && timeout 150 godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
    -- --autostart --autopilot --no-overlay --sky=partly --camera=cockpit "--seed=$SEED" \
    "$@" "--screenshot=$png" 2>&1 | grep -E "^screenshot:|ERROR" || true)
    # окно бывает вдвое уже экрана (тайлинг) — тогда кадр не годится, повтор
    [[ -f "$png" && "$(identify -format %w "$png")" -ge 1900 ]] && break
  done
  convert "$png" -quality 88 "$file"
  rm -f "$png"
}

for p in "${places[@]}"; do
  IFS='|' read -r name site lat lon off hdg <<<"$p"
  read -r az el < <(sun "$lat" "$lon" "$off" 20.6667)
  yaw="$(python3 -c "print('%.1f' % (($hdg - $az + 180) % 360 - 180))")"
  echo "$name: солнце 20:40 азимут $az высота $el, курс $hdg, взгляд $yaw,$el"
  set_speed 60
  if [[ "${HALO_ONLY:-0}" != 1 ]]; then
    shot "$out/${prefix}sunset_${name}.jpg" "--location=$name" "--site=$site" --hour=20 --time=40 "--look=$yaw,$el"
  fi
  # halo (HH-11): те же условия, имя для замера tools/shots/sun_halo_measure.py
  set_speed 60
  shot "$out/${prefix}halo_${name}.jpg" "--location=$name" "--site=$site" --hour=20 --time=40 "--look=$yaw,$el"
  set_speed 1
  [[ "${HALO_ONLY:-0}" == 1 ]] && continue
  shot "$out/${prefix}day_${name}.jpg" "--location=$name" "--site=$site" --hour=12 --time=20 --air-start=300,300 --look=0,25
done
echo "haze_humidity_shots.sh: кадры $prefix* в $out"
