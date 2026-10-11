#!/usr/bin/env bash
# A/B кадра над городом по координатам (osm-look OL-4): одна копия проекта (аргумент 1), один пресет, один прогон.
#   tools/bench/osm_ab.sh <копия_проекта> <метка A|B> <пресет> <прогон> <out_dir> [lat,lon] [air-start]
# Профиль Godot — постоянный out_dir/xdg_<пресет> (кеш места общий для A и B). Нужен DISPLAY=:0, под dp job.
set -uo pipefail
proj=${1:?копия}; tag=${2:?метка}; preset=${3:?пресет}; run=${4:?прогон}; out=${5:?out_dir}
latlon=${6:-43.238,76.945}; air=${7:-0,450}
mkdir -p "$out"; out=$(realpath "$out")
export DISPLAY="${DISPLAY:-:0}" XDG_DATA_HOME="$out/xdg"
mkdir -p "$XDG_DATA_HOME"
cd "$proj"
godot --headless --path . res://tools/bench/set_preset.tscn -- --preset="$preset" 2>&1 | grep -E "set_preset|ERROR" || true
name="${tag}_${preset}_${run}"
rm -f "$out/$name.jsonl"
systemd-run --user --scope -p MemoryMax=12G -q timeout 900 godot --path . --audio-driver Dummy --disable-vsync --fullscreen \
  --resolution 1920x1080 --gpu-profile res://tools/bench/frame_profile.tscn -- --location=almaty --latlon="$latlon" \
  --game-args="--air-start=$air" --tag="$tag-$preset" --marks=6:chase --sample=4 --exps=base --out="$out/$name.jsonl" \
  >"$out/$name.log" 2>&1
echo "$name exit=$? $(grep -E '^frame_profile:|PROFILE osm_buildings' "$out/$name.log" | tr '\n' ' ')"
git checkout -- project.godot 2>/dev/null
