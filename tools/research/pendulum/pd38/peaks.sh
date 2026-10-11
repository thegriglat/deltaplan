#!/bin/bash
# PD-38: пики удельной силы пилота на касании (оба режима) одним headless-прогоном Godot.
# Пишет tools/research/pendulum/pd38/out/peaks.txt (PD38_OUT — другой путь), печатает строки PEAK.
cd "$(dirname "$0")/../../../.." || exit 1
X=$(mktemp -d)
# новые class_name (PilotLegs) — в кэш классов
grep -q PilotLegs .godot/global_script_class_cache.cfg 2>/dev/null || XDG_DATA_HOME="$X" godot --headless --path . --import >/dev/null 2>&1
XDG_DATA_HOME="$X" godot --headless --path . res://tools/research/pendulum/pd38/peaks.tscn 2>&1 | grep '^PEAK'
rm -rf "$X"
