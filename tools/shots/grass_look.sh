#!/usr/bin/env bash
# Трава: 6 кадров в одних точках (шлюз 2, docs/plan/grass-rocks.md): Онгудай, ветер 3 м/с.
# tools/shots/grass_look.sh [выход]   (по умолчанию docs/screenshots/grass-look)
# Кадры: 1_cockpit, 2_chase, 3_side, 4_low_meadow, 5_mid_free, 6_mid_cockpit_far (.jpg).
# DP_GRASS_MID=blades|shell|cards (если задана) передаётся игре в окружении (GrassField.setup).
# Окну нужен настоящий дисплей (DISPLAY=:0), --fullscreen; звук выключен; каждый запуск — под timeout 120 с.
# Профиль Godot — постоянный профиль копии (XDG_DATA_HOME=~/.cache/dp-xdg/<копия>); для импорта первого
# запуска в копии: godot --headless --path . --import.
set -euo pipefail
cd "$(dirname "$0")/../.."

out="${1:-docs/screenshots/grass-look}"
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}"
mkdir -p "$XDG_DATA_HOME"

shot() {  # shot <файл> <аргументы игры...>
  local file="$1"
  shift
  echo "-- $(basename "$file")"
  timeout 120 godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
    -- --autostart --autopilot --location=ongudai --wind=3 "$@" "--screenshot=$file" 2>&1 \
    | grep -E "^screenshot:|ERROR|SCRIPT ERROR" || true
  if [[ ! -s "$file" ]]; then
    echo "WARN: нет кадра $file" >&2
  elif [[ $(stat -c %s "$file") -lt 51200 ]]; then
    echo "WARN: кадр меньше 50 КБ: $file" >&2
  fi
}

shot "$out/1_cockpit.jpg" --camera=cockpit --look=0,-15 --time=2
shot "$out/2_chase.jpg" --camera=chase --time=2
shot "$out/3_side.jpg" --camera=cockpit --look=70,-20 --time=2
shot "$out/4_low_meadow.jpg" --air-start=600,15 --camera=chase --time=3
shot "$out/5_mid_free.jpg" --camera=free --time=2
shot "$out/6_mid_cockpit_far.jpg" --camera=cockpit --look=0,-5 --time=2
echo "grass_look.sh: кадры в $out"
