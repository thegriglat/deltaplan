#!/usr/bin/env bash
# RW-10e: эталоны ongudai_* на запечённом поле. Использование: run_cases.sh <копия на c591b1026> <вывод> <поля> [случаи]
# Под замком cpu (окно без GPU-расчёта: поле читается из файла).
set -uo pipefail
ref="$1"; out="$2"; fields="$3"; only="${4:-ongudai_medium,ongudai_strong,ongudai_wave}"
here="$(cd "$(dirname "$0")" && pwd)"
cp "$here/gen_cases_baked.gd" "$here/gen_cases_baked.tscn" "$ref/tools/wind_fixtures/"
cd "$ref"
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile" tools/wind_fixtures/gen_cases_baked.gd tools/wind_fixtures/gen_cases_baked.gd.uid tools/wind_fixtures/gen_cases_baked.tscn' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
XDG_DATA_HOME="$profile" godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
	res://tools/wind_fixtures/gen_cases_baked.tscn -- --out="$out" --only="$only" --fields="$fields"
