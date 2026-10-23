#!/bin/bash
# Запуск из корня копии: tools/research/trike-pilot/run_sweep.sh <скрипт.gd> <выход.jsonl>
set -e
SRC=${1:-tools/research/trike-pilot/speed_sweep.gd}
OUT=${2:-tools/research/trike-pilot/speed_sweep.jsonl}
NAME=test_tp17_tmp
cp "$SRC" tests/game/$NAME.gd
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tests/run_tests.tscn -- --filter=$NAME 2>&1 | grep '^TP17 ' | sed 's/^TP17 //' > "$OUT" || true
rm -f tests/game/$NAME.gd tests/game/$NAME.gd.uid
wc -l "$OUT"
