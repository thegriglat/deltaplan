#!/usr/bin/env bash
# CR-14: смена места в сеансе. Нужен дисплей. run.sh --keys=<файл вне репозитория> --seq=A,A,B [--fly=40] [--bots=2] [--skip-fly]
set -uo pipefail
cd "$(dirname "$0")/../../../.."
export XDG_DATA_HOME="$HOME/.cache/dp-xdg/$(basename "$PWD")" DISPLAY="${DISPLAY:-:0}"
pg=$(mktemp); cp project.godot "$pg"; trap 'cmp -s project.godot "$pg" || cp "$pg" project.godot; rm -f "$pg"' EXIT
godot --path . --audio-driver Dummy --resolution 1280x720 res://tools/research/crash-reports/cr-14/repro.tscn -- "$@"
