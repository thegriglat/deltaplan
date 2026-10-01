#!/usr/bin/env bash
# run.sh <копия> <метка> [доп. аргументы dump_wind] — окно маленькое, временный профиль, GPU под flock.
set -uo pipefail
copy="$1"; label="$2"; shift 2
here="$(cd "$(dirname "$0")" && pwd)"
profile="$(mktemp -d)"
cp -r "$here" "$copy/tools/research/" 2>/dev/null || true
cd "$copy"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile"' EXIT
XDG_DATA_HOME="$profile" flock /tmp/heat_ca_gpu.lock godot --path . --audio-driver Dummy --resolution 320x240 \
  --disable-vsync --max-fps 60 res://tools/research/wind_compare/dump_wind.tscn -- \
  --out="$here/out/${label}.json" "$@"
