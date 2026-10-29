#!/usr/bin/env bash
# RW-11d: дамп CloudField/CloudPhysics на опорной ревизии c591b1026 (headless, без GPU).
# Использование: run_dump.sh <копия на c591b1026> <каталог вывода> <каталог поля Онгудая (field.json+field.bin)>
# Под замком cpu: .dpcli/dpcli lock cpu rw11d -- <этот скрипт> …
set -uo pipefail
ref="$1"; out="$2"; field="$3"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ref/tools/rw11d"
cp "$here/dump_clouds.gd" "$ref/tools/rw11d/"
printf '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://tools/rw11d/dump_clouds.gd" id="1"]\n\n[node name="DumpClouds" type="Node"]\nscript = ExtResource("1")\n' > "$ref/tools/rw11d/dump_clouds.tscn"
cd "$ref"
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile" "$ref/tools/rw11d"' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
XDG_DATA_HOME="$profile" godot --headless --path . res://tools/rw11d/dump_clouds.tscn -- "--out=$out" "--field=$field"
