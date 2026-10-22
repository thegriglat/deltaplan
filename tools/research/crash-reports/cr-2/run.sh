#!/usr/bin/env bash
# CR-2: повторные загрузки места в одной сессии. Нужен дисплей. tools/research/crash-reports/cr-2/run.sh [--loc=askarovo] [--cycles=6] [--fly=20] [--wind=18]
set -uo pipefail
cd "$(dirname "$0")/../../../.."
export XDG_DATA_HOME="$HOME/.cache/dp-xdg/$(basename "$PWD")" DISPLAY="${DISPLAY:-:0}"
pg=$(mktemp); cp project.godot "$pg"; trap 'cmp -s project.godot "$pg" || cp "$pg" project.godot; rm -f "$pg"' EXIT
godot --path . --audio-driver Dummy --resolution 1280x720 res://tools/research/crash-reports/cr-2/repro.tscn -- "$@"
