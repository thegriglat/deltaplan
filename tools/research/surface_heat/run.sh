#!/usr/bin/env bash
# SH-3: замер «до/после» surface-heat. Godot с окном 320x240 (RenderingDevice нужен для Пикара),
# временный профиль пилота, project.godot возвращается как был.
#   tools/research/surface_heat/run.sh <метка> [аргументы measure.gd: --places=… --hours=… --wind=…]
# Результат: tools/research/surface_heat/out/<метка>/<место>_h<час>.json + summary.csv (compare.py --summary)
set -uo pipefail
cd "$(dirname "$0")/../../.."
label="${1:?метка (before/after/…)}"
shift
out=tools/research/surface_heat/out/$label
mkdir -p "$out"
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile"' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
XDG_DATA_HOME="$profile" godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
	res://tools/research/surface_heat/measure.tscn -- --label="$label" --out="$out" "$@"
status=$?
python3 tools/research/surface_heat/compare.py --summary "$out"
exit $status
