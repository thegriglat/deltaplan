#!/usr/bin/env bash
# air-start AS-1: загрузка поля на слабом ветре по проходам (GPU, 320x240, под flock), затем GPU-тест
# test_air_start (откат к проходу 1). tools/research/air_start/slow_wind_run.sh (из корня копии).
set -uo pipefail
cd "$(dirname "$0")/../../.."
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile"' EXIT
XDG_DATA_HOME="$profile" flock /tmp/heat_ca_gpu.lock godot --path . --audio-driver Dummy --resolution 320x240 \
	res://tools/research/air_start/slow_wind_probe.tscn -- --out=tools/research/air_start/out/slow_wind.csv
