#!/usr/bin/env bash
# air-start AS-1: сходимость подстройки притока по проходам (GPU, окно 320x240, под flock).
# tools/research/air_start/passes_run.sh   (из корня копии); готовые ключи пропускаются.
set -uo pipefail
cd "$(dirname "$0")/../../.."
out=tools/research/air_start/out/passes.csv
scene=res://tools/research/air_start/passes_probe.tscn
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile"' EXIT
run() {
	XDG_DATA_HOME="$profile" flock /tmp/heat_ca_gpu.lock godot --path . --audio-driver Dummy \
		--resolution 320x240 "$scene" -- --out=$out "$@"
}
run --winds=6 --variants=warm,cold --passes=4
run --winds=3,10 --variants=warm --passes=4
