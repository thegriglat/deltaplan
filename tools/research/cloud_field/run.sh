#!/usr/bin/env bash
# CLF-1: день поля облачности над местами (dump.gd). Godot с окном 320x240 (RenderingDevice для
# Пикара), профиль своей копии (ongudai — в user://locations профиля; training_island — в паке;
# almaty — точка 43,20; 76,90, тайлы скачиваются в user://locations/pt_…).
#   tools/research/cloud_field/run.sh [--places=ongudai,training_island,almaty --weathers=weak,strong,windy
#                                      --frames=11,13,15 --h0=9 --h1=17 --out=tools/research/cloud_field/out]
set -uo pipefail
cd "$(dirname "$0")/../../.."
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}"
bak=$(mktemp)
cp project.godot "$bak"
trap 'cmp -s project.godot "$bak" || cp "$bak" project.godot; rm -f "$bak"' EXIT
godot --headless --path . --import >/dev/null 2>&1 || true
godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
	res://tools/research/cloud_field/dump.tscn -- "$@"
