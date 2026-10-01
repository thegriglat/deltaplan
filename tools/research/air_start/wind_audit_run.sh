#!/usr/bin/env bash
# WPC-2: профили ветра у стартов (К5) — аналитика (headless) и поле (GPU, окно 320x240, под flock).
# tools/research/air_start/wind_audit_run.sh [analytic|field|all] [out-подпапка] [аргументы поля…]
#   (из корня копии; по умолчанию out/after; например: … field after_p3 --passes=3)
# Готовые ключи (место, старт, режим, ветер) пропускаются — продолжение с места.
set -uo pipefail
cd "$(dirname "$0")/../../.."
what="${1:-all}"
out=tools/research/air_start/out/${2:-after}
shift $(( $# > 2 ? 2 : $# ))
mkdir -p "$out"
scene=res://tools/research/air_start/wind_audit.tscn
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile"' EXIT
if [[ "$what" == analytic || "$what" == all ]]; then
	XDG_DATA_HOME="$profile" godot --headless --path . "$scene" -- --out=$out/wind_profile.csv \
		--modes=analytic --winds=0,3,6,10 --terrain=$out/terrain_lines.json
fi
if [[ "$what" == field || "$what" == all ]]; then
	XDG_DATA_HOME="$profile" flock /tmp/heat_ca_gpu.lock godot --path . --audio-driver Dummy \
		--resolution 320x240 "$scene" -- --out=$out/wind_profile.csv --modes=field --winds=0,3,6,10 "$@"
fi
py="${PY:-/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python}"
# сводка WPC-2 (нужны обе моды и рельеф по линии ветра) — только в папке с аналитикой
[[ -f $out/terrain_lines.json ]] && AUDIT_OUT="$PWD/$out" "$py" tools/research/air_start/wind_audit.py
"$py" tools/research/air_start/compare.py "${out##*/}"
