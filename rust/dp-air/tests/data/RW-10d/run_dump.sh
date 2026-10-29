#!/usr/bin/env bash
# RW-10d: дамп AirThermals.build на опорной ревизии c591b1026 (окно, GPU).
# Использование: run_dump.sh <копия на c591b1026> <каталог вывода> [имя,имя]
# Под замком gpu: .dpcli/dpcli job --lock gpu start rw10d 3000 <этот скрипт> …
set -uo pipefail
ref="$1"; out="$2"; only="${3:-}"
here="$(cd "$(dirname "$0")" && pwd)"
cp "$here/dump_air_thermals.gd" "$here/dump_air_thermals.tscn" "$ref/tools/wind_fixtures/"
cd "$ref"
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile"' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
args=(--out="$out")
[ -n "$only" ] && args+=(--only="$only")
XDG_DATA_HOME="$profile" godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
	res://tools/wind_fixtures/dump_air_thermals.tscn -- "${args[@]}"
