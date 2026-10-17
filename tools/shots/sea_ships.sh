#!/usr/bin/env bash
# SEA-5/SEA-11: кадры шлюза sea-ships — горизонт с 300/1500 м и крупное судно на местах у моря.
#   bash tools/shots/sea_ships.sh [выход]   (по умолчанию /home/greg/deltaplan/build/screenshots/sea-ships/SEA-5)
# Профиль XDG_DATA_HOME должен содержать места pt_-27.700_-048.800 и pt_-27.100_-109.350 (нет — соберутся с сетью).
# Учебный остров — встроенное место (--location=training_island), данных из сети не надо.
# Нужен дисплей (DISPLAY=:0), GPU-замок не берём.
set -uo pipefail
cd "$(dirname "$0")/../.."
out="${1:-/home/greg/deltaplan/build/screenshots/sea-ships/SEA-11}"
export DISPLAY="${DISPLAY:-:0}" XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}"
mkdir -p "$out"
shoot() {  # shoot <тег> <lat,lon> [доп. аргументы]
  timeout 600 godot --path . --fullscreen --audio-driver Dummy --resolution 1920x1080 \
    res://tools/shots/sea_ships_shot.tscn -- ${2:+--place="$2"} ${LOC:+--location="$LOC"} --tag="$1" --out="$out" --game-args=${4:---hour=12} ${3:-} \
    2>&1 | grep -E "^sea_ships_shot:|SCRIPT ERROR|ERROR" || true
}
LOC=training_island shoot island ""
LOC= shoot florianopolis -27.7176,-48.7799
shoot rapanui -27.12,-109.35
shoot florianopolis_eve -27.7176,-48.7799 --mode=eve --hour=20
shoot rapanui_eve -27.12,-109.35 --mode=eve --hour=20
git checkout -- project.godot 2>/dev/null
ls "$out"
