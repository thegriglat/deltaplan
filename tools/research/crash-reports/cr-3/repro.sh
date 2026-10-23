#!/bin/bash
# CR-3: загрузка точки с карты тем же путём, что игра (Terrain.load_point → setup_async: стадии
# dem…trees…grass), в окне. Координаты — не в репозитории: файл с "lat,lon" (по умолчанию
# ~/.cache/dp-crash-reports/cr3_latlon.txt) или первым аргументом строка "lat,lon".
# Запуск из корня копии: tools/research/crash-reports/cr-3/repro.sh [lat,lon] > лог 2>&1
set -u
LL="${1:-$(cat ~/.cache/dp-crash-reports/cr3_latlon.txt)}"
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
exec godot --path . scenes/terrain/terrain_preview.tscn -- --latlon="$LL" --shot=/tmp/cr3_shot.png
