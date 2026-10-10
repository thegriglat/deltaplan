#!/usr/bin/env bash
# Размер pck (Linux-пресет, headless --export-pack, временный XDG): строка "pck_mb <число>".
set -e
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --export-pack "Linux" "$out/game.pck" >"$out/log.txt" 2>&1 || { tail -20 "$out/log.txt"; exit 1; }
bytes=$(stat -c %s "$out/game.pck")
echo "pck_mb $(awk -v b="$bytes" 'BEGIN{printf "%.1f", b/1048576}')"
rm -rf "$out"
