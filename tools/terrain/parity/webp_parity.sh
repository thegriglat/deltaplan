#!/usr/bin/env bash
# Сравнение мест N5 (WebP) со старым форматом из коммита 6a94ddb: max_dh_m, raster_mismatch;
# с --time ещё read_ratio (новое/старое время чтения). Запуск из любой папки.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OLD_COMMIT=6a94ddb
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -C "$ROOT" archive "$OLD_COMMIT" data/terrain | tar -x -C "$TMP"
XDG_DATA_HOME="$(mktemp -d)" godot --headless --path "$ROOT" -s res://tools/terrain/parity/webp_parity.gd -- \
  "$TMP/data/terrain" "$ROOT/data/terrain" "$@" 2>&1 | grep -E '^(max_dh_m|raster_|read_)'
