#!/usr/bin/env bash
# RW-10f: эталоны thermal у облаков. Использование: run_cloud_cases.sh <копия на c591b1026> <вывод> <поля> [случаи]
# synth_* идут без окна (--synthetic), ongudai_* - в окне без GPU-расчёта (поле читается из файла).
# Под замком cpu.
set -uo pipefail
ref="$1"; out="$2"; fields="$3"; only="${4:-synth_weak,synth_medium,synth_strong,synth_storm,ongudai_medium,ongudai_strong,ongudai_wave}"
here="$(cd "$(dirname "$0")" && pwd)"
cp "$here/gen_cloud_cases.gd" "$ref/tools/wind_fixtures/"
sed 's#gen_fixtures.gd#gen_cloud_cases.gd#' "$ref/tools/wind_fixtures/gen_fixtures.tscn" > "$ref/tools/wind_fixtures/gen_cloud_cases.tscn"
cd "$ref"
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile" tools/wind_fixtures/gen_cloud_cases.gd tools/wind_fixtures/gen_cloud_cases.gd.uid tools/wind_fixtures/gen_cloud_cases.tscn' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
syn=""; ong=""
IFS=, read -ra A <<< "$only"
for n in "${A[@]}"; do case "$n" in synth_*) syn="$syn,$n";; *) ong="$ong,$n";; esac; done
rc=0
if [ -n "$syn" ]; then
	XDG_DATA_HOME="$profile" godot --headless --path . res://tools/wind_fixtures/gen_cloud_cases.tscn -- --out="$out" --synthetic --only="${syn#,}" --fields="$fields" || rc=1
fi
if [ -n "$ong" ]; then
	XDG_DATA_HOME="$profile" godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
		res://tools/wind_fixtures/gen_cloud_cases.tscn -- --out="$out" --only="${ong#,}" --fields="$fields" || rc=1
fi
exit $rc
