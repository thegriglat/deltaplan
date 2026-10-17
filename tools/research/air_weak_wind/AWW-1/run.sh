#!/bin/bash
# AWW-1: прогоны probe.tscn по стартам встроенных мест (окно — GPU, как lee_cal/run.sh).
# run.sh <метка> [старт…]; старт — place/site[:calc|:baked] (без суффикса — calc и baked);
# пишет out/<метка>/<place>_<site>_<calc|baked>.json и .log. Пачка: .dpcli/dpcli job start aww-<метка> 7200 tools/research/air_weak_wind/AWW-1/run.sh <метка>
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../../.." && pwd)"; cd "$ROOT" || exit 2
export XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$ROOT")}
TAG=${1:?метка}; shift
O=$HERE/out/$TAG; mkdir -p "$O"
# импорт: после правки .glsl без него берётся старый SPIR-V
godot --headless --path . --import > "$O/import.log" 2>&1 || true
git checkout -- project.godot 2>/dev/null || true
ALL=(training_island/ridge_west training_island/thermal_plain training_island/landing_hill training_island/lee_bowl
     volcano_island/east_cliffs volcano_island/crater_ridge volcano_island/thermal_slope volcano_island/plateau_landing)
NAMES=("$@"); [ ${#NAMES[@]} -eq 0 ] && NAMES=("${ALL[@]}")
for n in "${NAMES[@]}"; do
  ps=${n%%:*}; mode=""; [[ "$n" == *:* ]] && mode=${n##*:}
  place=${ps%%/*}; site=${ps##*/}
  modes=(calc baked); [ -n "$mode" ] && modes=("$mode")
  for m in "${modes[@]}"; do
    nb=""; [ "$m" = calc ] && nb="--nobake"
    f=$O/${place}_${site}_$m
    DISPLAY="${DISPLAY:-:0}" timeout 1500 godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
      res://tools/research/air_weak_wind/AWW-1/probe.tscn -- --autostart --bots=0 --location=$place --site=$site $nb \
      --secs=60 --out=$f.json > $f.log 2>&1
    echo "$place/$site $m: $(grep -o 'aww_probe: .*' $f.log) | $(grep -o 'air_model: поле (.*' $f.log | tail -1 | cut -c1-200)"
  done
done
git checkout -- project.godot 2>/dev/null || true
