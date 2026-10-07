#!/bin/bash
# run_one.sh <место> <ветер м/с> <час> <лог> — один замер загрузки (под замком GPU снаружи)
cd "$(dirname "$0")/../../.."
X=$(mktemp -d)
XDG_DATA_HOME=$X timeout 200 godot --path . --audio-driver Dummy --resolution 1280x720 \
  res://tools/research/qol_load/probe.tscn -- --location=$1 --wind=$2 --hour=$3 --timeout=150 --no-shots > "$4" 2>&1
echo "exit=$?" >> "$4"
rm -rf "$X"
