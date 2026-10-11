#!/bin/bash
# PD-38: вывод тестов земли/посадки/разбега (печать чисел) → $1 (для сравнения до/после правки ног)
cd "$(dirname "$0")/../../../.." || exit 1
OUT=${1:?файл вывода}
X=$(mktemp -d)
: > "$OUT"
for t in test_pendulum_takeoff_pilot test_pendulum_ground test_pendulum_run_smooth test_pendulum_landing_technique test_pendulum_ground_landing test_landing.gd test_takeoff test_liftoff_physics test_motion_ground; do
  echo "=== $t" >> "$OUT"
  XDG_DATA_HOME="$X" godot --headless --path . res://tests/run_tests.tscn -- --filter="$t" 2>&1 | grep -v '^Godot Engine\|^steam:' >> "$OUT"
done
rm -rf "$X"
