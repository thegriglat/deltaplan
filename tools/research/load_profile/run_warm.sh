#!/bin/bash
# run_warm.sh <тег> <место> <суффикс> — тёплые запуски в профиле после run_pair.sh (кеш уже есть). Под замком GPU.
cd "$(dirname "$0")/../../.."
tag=$1; place=$2; suf=$3
L=tools/research/load_profile/logs
X=$HOME/.cache/dp-xdg/loadprof-$tag
for run in 1 2; do
  XDG_DATA_HOME=$X timeout 900 godot --path . --audio-driver Dummy --resolution 1280x720 \
    res://tools/lp_tmp/probe.tscn -- $place --timeout=800 --no-shots > "$L/${tag}_${suf}$run.log" 2>&1
  echo "exit=$?" >> "$L/${tag}_${suf}$run.log"
done
