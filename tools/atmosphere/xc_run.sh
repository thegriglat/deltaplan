#!/usr/bin/env bash
# Бот-маршрутник (FR-34a): headless-прогон маршрута, статистика полёта в JSON.
#   tools/atmosphere/xc_run.sh [флаги xc_run]         — один прогон (по умолчанию Онгудай, 30 км)
#   tools/atmosphere/xc_run.sh --synthetic --seed=3   — синтетика: плоская земля, сетка термиков
# Флаги: --location=ongudai --weather=medium --seed=1 --wind=15,270 --km=30 --out=<json>
#        --clouds --course=<°> --start-agl=300 --time-limit=<с> --wing=sport --no-thermals
#        --bg=<м/с> --turbulence=0|1 --grid=<м> --lateral=<м> --trace=<с>
# Без --out JSON печатается в stdout. Подробности — шапка tests/atmosphere/xc/xc_run.gd.
set -euo pipefail
cd "$(dirname "$0")/../.."
has_loc=0
for a in "$@"; do [[ $a == --location=* || $a == --synthetic ]] && has_loc=1; done
extra=()
if [[ $has_loc == 0 ]]; then extra=(--location=ongudai); fi
exec godot --headless --path . res://tests/atmosphere/xc/xc_run.tscn -- "${extra[@]}" "$@"
