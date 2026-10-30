#!/usr/bin/env bash
# RW-21a: T9 synthetic 30 км (бот xc_run.gd) на release-расширении; печатает время и итог.
# Запускать под замком: .dpcli/dpcli lock cpu RW-21a -- tools/smoke/t9_30km.sh [таймаут_с=2400] [--nondet…]
set -uo pipefail
cd "$(dirname "$0")/../.."
to="${1:-2400}"; shift || true
out=build/smoke/RW-21a; mkdir -p "$out"
[[ -e addons/dp_air/bin/libdp_air_tune.so ]] || cp addons/dp_air/bin/libdp_air_release.so addons/dp_air/bin/libdp_air_tune.so
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}"
s=$(date +%s)
timeout "$to" godot --headless --path . res://tests/atmosphere/xc/xc_run.tscn -- \
	--synthetic --seed=1 --wind=0,0 --km=30 --out="$out/t9_30km.json" "$@" >"$out/t9_30km.log" 2>&1
echo "rc=$? wall_s=$(( $(date +%s) - s ))"
tail -5 "$out/t9_30km.log"
