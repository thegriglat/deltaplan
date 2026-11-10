#!/usr/bin/env bash
# run_probe.sh <копия> <лог> [LT11_ONLY=через запятую]: зонд LT-11 в копии с LTM v1 (lee-turb-LT-11-ltm)
set -uo pipefail
wt=$1; log=$2; only=${3:-}
d=$(cd "$(dirname "$0")" && pwd)
export XDG_DATA_HOME=$HOME/.cache/dp-xdg/${LT11_XDG:-lee-turb-LT-11}
export LT11_ONLY=$only
"$d/make_probe.sh" "$wt"
cd "$wt"
[ -d .godot/imported ] || godot --headless --path . --import >/dev/null 2>&1
godot --headless --path . res://tests/run_tests.tscn -- --file=res://tests/atmosphere/probe_lee.gd --ridge-full > "$log" 2>&1
echo "exit=$?" >> "$log"
