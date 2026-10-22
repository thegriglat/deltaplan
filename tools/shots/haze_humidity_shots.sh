#!/usr/bin/env bash
# Кадры до/после модуля haze-humidity (карточка HH-10): закат из кабины и основание облаков днём.
# tools/shots/haze_humidity_shots.sh <корень_копии> <префикс> [выход]
#   корень_копии — копия игры (main для «до», ветка модуля для «после»); префикс — before_ | after_.
#   выход по умолчанию — /home/greg/deltaplan/build/screenshots/haze-humidity
# Кадры <префикс>sunset_<место>.jpg и <префикс>day_<место>.jpg, JPEG q88, 1920x1080.
# Условия (одни и те же для до и после): 15 июля (по умолчанию), --seed=7, --sky=partly, кабина,
#   синтетический пилот, без прибора.
#   Закат: --hour=20 + 40 с полёта при времени ×60 (минута за секунду; world.json → time.speed
#   берётся из временной правки профиля user://configs/world.json) = 20:40. Взгляд к солнцу:
#   рыскание = курс старта − азимут солнца (+ влево), тангаж = высота солнца; считается по тем
#   же формулам NOAA, что SunClock.solar_position.
#   День: --hour=12, старт в воздухе (--air-start: 300 м от старта, 300 м над рельефом; со склона
#   днём автопилот сразу падает), 20 с полёта, время ×1, взгляд 0,25 (вверх, на основание облаков).
# Профиль Godot — XDG_DATA_HOME копии (по умолчанию ~/.cache/dp-xdg/<имя папки копии>).
# Окну нужен настоящий дисплей (DISPLAY=:0); каждый запуск — под timeout 150 с.
set -euo pipefail
root="$(cd "${1:?корень копии}" && pwd)"
prefix="${2:?префикс: before_ | after_}"
out="${3:-/home/greg/deltaplan/build/screenshots/haze-humidity}"
mkdir -p "$out"
export DP_SUN_TINT_LOG=1
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

# max_hour 23: ход часов дальше 21:00 нужен кадрам при солнце < 2° (по умолчанию время в полёте стоит с 21:00)
set_speed() { echo "{\"time\": {\"speed\": $1, \"max_hour\": 23}}" > "$cfg"; }

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
    "$@" "--screenshot=$png" 2>&1 | tee "${png%.png}.log" | grep -E "^screenshot:|ERROR" || true)
    [[ -f "$png" ]] && break
  done
  convert "$png" -quality 88 "$file"
  # ожидаемая цветность диска (SkyEnvironment, DP_SUN_TINT_LOG) — для tools/shots/sun_color_measure.py
  grep "^sun_tint:" "${png%.png}.log" | tail -1 > "${file%.jpg}.tint.txt" || true
  rm -f "$png" "${png%.png}.log"
}

# Режим suncolor (HH-13): закат при высоте солнца 4°, 2° и 0,7° (время — по расчёту высоты, не по часам),
# ракурсы «к солнцу» и «сбоку» (на освещённые бока облаков, солнце сбоку) в Аскарово:
# <префикс>suncolor_askarovo[_low][_side].jpg; и вечерний Эверест (ракурс 26_everest_tele (= 03_эверест_вечером) из menu_art.json) —
# <префикс>everest.jpg. Диск рисуется не ниже min_light_elevation_deg (2°), цветность — по истинной высоте.
if [[ "${4:-}" == "suncolor" ]]; then
  IFS='|' read -r name site lat lon off hdg <<<"${places[1]}"
  for tgt in "4.0:" "2.0:_low" "0.7:_vlow"; do
    want="${tgt%%:*}"; sfx="${tgt##*:}"
    # час (дробный), когда высота солнца = want (бисекция по вечернему спаду)
    h="$(python3 - "$want" "$lat" "$lon" "$off" <<'PY'
import sys
want, lat, lon, off = sys.argv[1:5]
import math
doy = 196
def elev(h, lat=float(lat), lon=float(lon), off=float(off)):
    g = 2 * math.pi / 365 * (doy - 1 + (h - 12) / 24)
    d = (0.006918 - 0.399912 * math.cos(g) + 0.070257 * math.sin(g) - 0.006758 * math.cos(2 * g)
         + 0.000907 * math.sin(2 * g) - 0.002697 * math.cos(3 * g) + 0.00148 * math.sin(3 * g))
    e = 229.18 * (0.000075 + 0.001868 * math.cos(g) - 0.032077 * math.sin(g) - 0.014615 * math.cos(2 * g)
                  - 0.040849 * math.sin(2 * g))
    s = h + (4 * lon - 60 * off + e) / 60
    ha = math.radians(15 * (s - 12)); la = math.radians(lat)
    return math.degrees(math.asin(math.sin(la) * math.sin(d) + math.cos(la) * math.cos(d) * math.cos(ha)))
lo, hi, w = 18.0, 23.0, float(want)
for _ in range(60):
    m = (lo + hi) / 2
    if elev(m) > w: lo = m
    else: hi = m
print("%.4f" % lo)
PY
)"
    hour=20  # старт — из time.start_hours (20:00), дальше время ×60: минута за секунду полёта
    secs="$(python3 -c "print('%.1f' % (($h - $hour) * 60))")"
    read -r az el < <(sun "$lat" "$lon" "$off" "$h")
    echo "$name: высота солнца $el (цель $want), час $h = --hour=$hour --time=$secs, азимут $az"
    set_speed 60
    # к солнцу: диск не ниже min_light_elevation_deg (2°)
    yaw="$(python3 -c "print('%.1f' % (($hdg - $az + 180) % 360 - 180))")"
    look_el="$(python3 -c "print(max($el, 2.0))")"
    shot "$out/${prefix}suncolor_${name}${sfx}.jpg" "--location=$name" "--site=$site" "--hour=$hour" "--time=$secs" --air-start=300,300 --sky=clear "--look=$yaw,$look_el"
    # сбоку: взгляд на 70° левее направления на солнце, чуть вверх (освещённые бока облаков)
    yaw2="$(python3 -c "print('%.1f' % (($hdg - $az + 180 + 70) % 360 - 180))")"
    shot "$out/${prefix}suncolor_${name}${sfx}_side.jpg" "--location=$name" "--site=$site" "--hour=$hour" "--time=$secs" --air-start=300,300 "--look=$yaw2,6"
  done
  ev="$(mktemp -d)"
  echo "-- ${prefix}everest.jpg"
  (cd "$root" && python3 tools/shots/menu_art.py --only=26 --size=1920x1080 "--out=$ev" 2>&1 | tail -3) || true
  cp "$ev"/26_*.jpg "$out/${prefix}everest.jpg"
  echo "haze_humidity_shots.sh: suncolor $prefix* в $out"
  exit 0
fi

for p in "${places[@]}"; do
  IFS='|' read -r name site lat lon off hdg <<<"$p"
  read -r az el < <(sun "$lat" "$lon" "$off" 20.6667)
  yaw="$(python3 -c "print('%.1f' % (($hdg - $az + 180) % 360 - 180))")"
  echo "$name: солнце 20:40 азимут $az высота $el, курс $hdg, взгляд $yaw,$el"
  set_speed 60
  shot "$out/${prefix}sunset_${name}.jpg" "--location=$name" "--site=$site" --hour=20 --time=40 "--look=$yaw,$el"
  set_speed 1
  shot "$out/${prefix}day_${name}.jpg" "--location=$name" "--site=$site" --hour=12 --time=20 --air-start=300,300 --look=0,25
done
echo "haze_humidity_shots.sh: кадры $prefix* в $out"
