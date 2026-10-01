#!/usr/bin/env bash
# SP-3: поле после решателя из подготовки нынешнего кода (GPU, окно): сохранить или сверить.
# tools/atmosphere/air_prep_ref_gpu.sh --solve=<папка> | --compare=<папка>
# Общий GPU — под замком: flock -w 1800 /tmp/heat_ca_gpu.lock tools/atmosphere/air_prep_ref_gpu.sh …
set -uo pipefail
cd "$(dirname "$0")/../.."
profile="$(mktemp -d)"
pg_backup="$profile/project.godot.bak"
cp project.godot "$pg_backup"
trap 'cmp -s project.godot "$pg_backup" || cp "$pg_backup" project.godot; rm -rf "$profile"' EXIT
XDG_DATA_HOME="$profile" godot --path . --audio-driver Dummy --resolution 320x240 \
	res://tools/atmosphere/air_prep_ref.tscn -- "$@"
