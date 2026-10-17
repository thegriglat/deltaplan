#!/usr/bin/env bash
# Кадры собаки на разбеге и в лагере (DOG-3): один прогон tools/shots/start_dog_shot.tscn.
# tools/shots/start_dog_run.sh [каталог] [-- аргументы игры…]
# По умолчанию: /home/greg/deltaplan/build/screenshots/start-dog/DOG-3 (задачи передают свой каталог). Нужен дисплей (DISPLAY=:0).
# Профиль — постоянный профиль копии (свежий качает рельеф 2–4 мин): $DP_XDG или ~/.cache/dp-xdg/<копия>.
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-/home/greg/deltaplan/build/screenshots/start-dog/DOG-3}"
[[ $# -gt 0 ]] && shift
[[ "${1:-}" == "--" ]] && shift
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"
xdg="${DP_XDG:-$HOME/.cache/dp-xdg/$(basename "$PWD")}"
env XDG_DATA_HOME="$xdg" timeout 1000 godot --path . --audio-driver Dummy --fullscreen \
	--resolution 1920x1080 res://tools/shots/start_dog_shot.tscn -- --autostart --egg=start_dog:0 \
	"--out=$out" "$@" 2>&1 | grep --line-buffered -E "^start_dog_shot:|ERROR|SCRIPT ERROR|Parse Error"
