#!/bin/bash
# PD-39: пики удельной силы пилота на аварии (оба режима, 120 и 240 Гц) одним headless-прогоном Godot.
# Пишет tools/research/pendulum/pd39/out/crash.txt (PD39_OUT — другой путь), печатает строки CRASH.
cd "$(dirname "$0")/../../../.." || exit 1
X=$(mktemp -d)
XDG_DATA_HOME="$X" godot --headless --path . res://tools/research/pendulum/pd39/crash.tscn 2>&1 | grep -E '^(CRASH|guard_resets_total)'
rm -rf "$X"
