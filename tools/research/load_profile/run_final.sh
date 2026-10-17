#!/bin/bash
# Финальные тёплые замеры (разметка всех кругов), нагрузка машины — в начале лога. Под замком GPU.
cd "$(dirname "$0")/../../.."
L=tools/research/load_profile/logs
for spec in "ong --location=ongudai" "pt --latlon=-27.7176,-48.7799"; do
  set -- $spec
  for run in 1 2; do
    f=$L/${1}_final$run.log
    echo "uptime: $(uptime)" > $f
    XDG_DATA_HOME=$HOME/.cache/dp-xdg/loadprof-$1 timeout 900 godot --path . --audio-driver Dummy --resolution 1280x720 \
      res://tools/lp_tmp/probe.tscn -- $2 --timeout=800 --no-shots >> $f 2>&1
    echo "exit=$?" >> $f
    echo "uptime_end: $(uptime)" >> $f
  done
done
