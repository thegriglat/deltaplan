#!/bin/bash
# PD-35: прогон тестов godot в копии: gt.sh <фильтр> [env K=V ...]; вывод — в stdout
cd "$(dirname "$0")/../../../.." || exit 1
X=$(mktemp -d)
exec systemd-run --user --scope -p MemoryMax=12G -q env XDG_DATA_HOME="$X" "${@:2}" godot --headless --path . res://tests/run_tests.tscn -- --filter="$1"
