#!/usr/bin/env bash
# RW-11f: дамп объектов-облаков W6 v4 на опорной ревизии c591b1026 (headless).
# Использование: run_dump.sh <копия на c591b1026> <файл вывода.json> [имя,имя]
# Под замком cpu: .dpcli/dpcli lock cpu rw11f -- <этот скрипт> …
set -uo pipefail
ref="$1"; out="$2"; only="${3:-}"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ref/tools/wind_fixtures/rw11f"
cp "$here/dump_cloud_objects.gd" "$here/dump_cloud_objects.tscn" "$ref/tools/wind_fixtures/rw11f/"
cd "$ref"
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile" "$ref/tools/wind_fixtures/rw11f"' EXIT
sed -i 's#wind_fixtures/dump_cloud_objects#wind_fixtures/rw11f/dump_cloud_objects#' tools/wind_fixtures/rw11f/dump_cloud_objects.tscn
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
args=(--out="$out")
[ -n "$only" ] && args+=(--only="$only")
XDG_DATA_HOME="$profile" godot --headless --path . res://tools/wind_fixtures/rw11f/dump_cloud_objects.tscn -- "${args[@]}"
