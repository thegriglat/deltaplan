#!/usr/bin/env bash
# FBW-1: сценарий пилота headless (путь термиков — аналитика; вход поля H, z_i, w* — на CPU).
# bash tools/research/fb1013_evening/run.sh [--places=ongudai,...] [--conds=evening,day] [--minutes=10]
# Пишет out/headless.csv, печатает таблицу и строку ИТОГ.
set -uo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p tools/research/fb1013_evening/out
profile="$(mktemp -d)"
trap 'rm -rf "$profile"' EXIT
XDG_DATA_HOME="$profile" systemd-run --user --scope -q -p MemoryMax=12G timeout 3600 \
	godot --headless --path . res://tools/research/fb1013_evening/probe.tscn -- \
	--out=tools/research/fb1013_evening/out/headless.csv "$@" 2>&1 | grep -E "^FB1013|ИТОГ|SCRIPT ERROR|Parse Error"
