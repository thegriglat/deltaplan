#!/bin/bash
# Все прогоны PendulumModel для TW-16 (из корня копии). Окружение: godot 4.7.2, XDG_DATA_HOME — профиль копии.
cd "$(git rev-parse --show-toplevel)"
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
R=res://tools/research/tow/tow_sweep.tscn
O=tools/research/tow/out
SWEEP=TRIM godot --headless --path . $R > $O/model_trim.txt
for e in 20 45 60; do SWEEP=T AT=pilot EPS=$e godot --headless --path . $R > $O/model_link_pilot_eps$e.txt; done
for e in 20 45; do
  SWEEP=FORCE AT=pilot EPS=$e godot --headless --path . $R > $O/model_force_pilot_eps$e.txt
  SWEEP=FORCE AT=split EPS=$e godot --headless --path . $R > $O/model_force_split_eps$e.txt
done
# аэробуксир (якорь выше): отдельный случай
SWEEP=T AT=pilot EPS=-10 godot --headless --path . $R > $O/model_link_pilot_epsm10.txt
