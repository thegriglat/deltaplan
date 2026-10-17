#!/bin/bash
# run_pair.sh <тег> <аргумент места: --location=ongudai | --latlon=lat,lon> [доп. аргументы зонда]
# Холодный (пустой профиль XDG) и затем тёплый (тот же профиль, кеш есть) запуск зонда загрузки.
# Логи: logs/<тег>_cold.log, logs/<тег>_warm.log, logs/<тег>_warm2.log. Под замком GPU снаружи.
cd "$(dirname "$0")/../../.."
tag=$1; place=$2; shift 2
L=tools/research/load_profile/logs
X=${XDG_ROOT:-$HOME/.cache/dp-xdg/loadprof-$tag}
rm -rf "$X"; mkdir -p "$X"
for run in cold warm warm2; do
  XDG_DATA_HOME=$X timeout 900 godot --path . --audio-driver Dummy --resolution 1280x720 \
    res://tools/lp_tmp/probe.tscn -- $place --timeout=800 --no-shots "$@" > "$L/${tag}_$run.log" 2>&1
  echo "exit=$?" >> "$L/${tag}_$run.log"
done
