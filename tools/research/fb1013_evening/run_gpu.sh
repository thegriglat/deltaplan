#!/usr/bin/env bash
# FBW-1: тот же сценарий с полем воздуха (GPU, окно 320x240) — путь, который пилот видит по умолчанию.
# bash tools/research/fb1013_evening/run_gpu.sh [--places=...] [--conds=...] [--out=...]
set -uo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p tools/research/fb1013_evening/out
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile"' EXIT
XDG_DATA_HOME="$profile" systemd-run --user --scope -q -p MemoryMax=12G timeout 3600 \
	godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
	res://tools/research/fb1013_evening/probe.tscn -- \
	--out=tools/research/fb1013_evening/out/gpu.csv "$@" 2>&1 | grep -E "^FB1013|ИТОГ|SCRIPT ERROR|Parse Error"
