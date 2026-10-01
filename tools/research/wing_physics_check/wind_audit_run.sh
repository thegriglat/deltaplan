#!/usr/bin/env bash
# WPC-2: профили ветра у стартов (К5) — аналитика (headless) и поле (GPU, окно 320x240, под flock).
# tools/research/wing_physics_check/wind_audit_run.sh [analytic|field|all]   (из корня копии)
# Готовые ключи (место, старт, режим, ветер) пропускаются — продолжение с места.
set -uo pipefail
cd "$(dirname "$0")/../../.."
what="${1:-all}"
out=tools/research/wing_physics_check/out
scene=res://tools/research/wing_physics_check/wind_audit.tscn
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile"' EXIT
if [[ "$what" == analytic || "$what" == all ]]; then
	XDG_DATA_HOME="$profile" godot --headless --path . "$scene" -- --out=$out/wind_profile.csv \
		--modes=analytic --winds=0,3,6,10 --terrain=$out/terrain_lines.json
fi
if [[ "$what" == field || "$what" == all ]]; then
	XDG_DATA_HOME="$profile" flock /tmp/heat_ca_gpu.lock godot --path . --audio-driver Dummy \
		--resolution 320x240 "$scene" -- --out=$out/wind_profile.csv --modes=field --winds=0,3,6,10
fi
"${PY:-/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python}" tools/research/wing_physics_check/wind_audit.py
