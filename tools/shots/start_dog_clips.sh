#!/usr/bin/env bash
# Кадры клипов собаки на старте (DOG-1): по запуску игры на клип, клип — через DP_DOG_CLIP (читает
# только start_dog.gd; при ней собака стоит в shot_side_m сбоку от пилота — лагерь со старта бывает
# за бровкой). Аргументы как у tools/shots/easter_egg_shot.sh, но: без --autopilot (пилот стоит на
# старте), постоянный профиль копии (свежий профиль качает рельеф ~2–4 мин — не укладывается в
# таймаут easter_egg_shot.sh), кадр на 4-й с, телеобъектив --fov=30.
# tools/shots/start_dog_clips.sh [каталог] [клипы…] [-- аргументы игры…]
# По умолчанию: /home/greg/deltaplan/build/screenshots/start-dog/DOG-1, все 8 клипов.
# Профиль: $DP_XDG или ~/.cache/dp-xdg/<имя копии>. Нужен дисплей (DISPLAY=:0).
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-/home/greg/deltaplan/build/screenshots/start-dog/DOG-1}"
[[ $# -gt 0 ]] && shift
clips=()
while [[ $# -gt 0 && "$1" != "--" ]]; do clips+=("$1"); shift; done
[[ "${1:-}" == "--" ]] && shift
[[ ${#clips[@]} -eq 0 ]] && clips=(gallop trot walk idle bark lie sit sniff)
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"
xdg="${DP_XDG:-$HOME/.cache/dp-xdg/$(basename "$PWD")}"
n=0
for c in "${clips[@]}"; do
	n=$((n + 1))
	f="$(printf '%s/%02d_%s.jpg' "$out" "$n" "$c")"
	echo "== $c -> $f"
	env DP_DOG_CLIP="$c" XDG_DATA_HOME="$xdg" timeout 400 godot --path . --audio-driver Dummy --fullscreen \
		--resolution 1920x1080 -- --autostart --egg=start_dog:1 --time=4 --look-at=egg:start_dog --fov=30 \
		--no-overlay "$@" "--screenshot=$f" 2>&1 | grep -E "^screenshot:|ERROR|SCRIPT ERROR" || true
done
