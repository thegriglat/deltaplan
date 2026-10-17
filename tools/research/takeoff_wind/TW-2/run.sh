#!/bin/bash
# TW-2: прогоны probe.tscn у старта «Термики» учебного острова с вариантами (окно — GPU, как lee_cal/run.sh).
# run.sh <метка> [вариант…]; пишет out/<метка>/<вариант>.json и .log. Переключатели вариантов — exp_switches.patch
# (TW2_FREE_WEATHER, TW2_HEAT_DOM, TW2_HEAT_WIN, TW2_NO_WINDOWS) и прототип правки — применять до запуска.
# Под замком GPU: .dpcli/dpcli job --lock gpu start tw2-<метка> 7200 tools/research/takeoff_wind/TW-2/run.sh <метка>
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../../.." && pwd)"; cd "$ROOT" || exit 2
export XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$ROOT")}
TAG=${1:?метка}; shift
O=$HERE/out/$TAG; mkdir -p "$O"
# импорт: после правки .glsl без него берётся старый SPIR-V
godot --headless --path . --import > "$O/import.log" 2>&1 || true
TI="--location=training_island --site=thermal_plain"
FREE="--hour=12 --wind=2 --from=180 --temp=25 --sky=partly"
declare -A A=(
 [baked]="$TI"
 [calc]="$TI --nobake"
 [free12]="$TI --nobake $FREE"
 [h9]="$TI --nobake --hour=9 --wind=2 --from=180 --temp=25 --sky=partly"
 [h15]="$TI --nobake --hour=15 --wind=2 --from=180 --temp=25 --sky=partly"
 [overcast]="$TI --nobake --hour=12 --wind=2 --from=180 --temp=25 --sky=overcast"
 [w4]="$TI --nobake --hour=12 --wind=4 --from=180 --temp=25 --sky=partly"
 [noheat]="$TI --nobake"
 [winnoheat]="$TI --nobake"
 [domnoheat]="$TI --nobake"
 [nowin]="$TI --nobake"
 [obs1]="--mode=obs1"
 [ridge_west]="--location=training_island --site=ridge_west"
 [ridge_west_calc]="--location=training_island --site=ridge_west --nobake"
 [landing_hill_calc]="--location=training_island --site=landing_hill --nobake"
 [lee_bowl_calc]="--location=training_island --site=lee_bowl --nobake"
 [crater_ridge_calc]="--location=volcano_island --site=crater_ridge --nobake"
 [east_cliffs_calc]="--location=volcano_island --site=east_cliffs --nobake"
 [plateau_landing_calc]="--location=volcano_island --site=plateau_landing --nobake"
 [thermal_slope_calc]="--location=volcano_island --site=thermal_slope --nobake"
 [ongudai]="--location=ongudai --site=kayancha_south --hour=12 --wind=3 --from=151 --sky=clear"
 [askarovo_w]="--location=askarovo --site=biyagoda_west --hour=12 --wind=3 --from=294 --sky=clear"
 [askarovo_e]="--location=askarovo --site=biyagoda_east --hour=12 --wind=3 --from=94 --sky=clear"
 [ongudai_w2]="--location=ongudai --site=kayancha_south --hour=12 --wind=2 --from=151 --sky=clear"
 [askarovo_w2]="--location=askarovo --site=biyagoda_west --hour=12 --wind=2 --from=294 --sky=clear"
)
declare -A E=(
 [h9]="TW2_FREE_WEATHER=1" [h15]="TW2_FREE_WEATHER=1" [free12]="TW2_FREE_WEATHER=1" [overcast]="TW2_FREE_WEATHER=1" [w4]="TW2_FREE_WEATHER=1"
 [noheat]="TW2_HEAT_DOM=0 TW2_HEAT_WIN=0" [winnoheat]="TW2_HEAT_WIN=0" [domnoheat]="TW2_HEAT_DOM=0" [nowin]="TW2_NO_WINDOWS=1"
)
NAMES=("$@"); [ ${#NAMES[@]} -eq 0 ] && NAMES=(baked calc free12 h9 h15 overcast w4 noheat winnoheat domnoheat nowin obs1)
for n in "${NAMES[@]}"; do
  env ${E[$n]} DISPLAY="${DISPLAY:-:0}" timeout 1200 godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
    res://tools/research/takeoff_wind/TW-2/probe.tscn -- --autostart --bots=0 ${A[$n]} --secs=60 --out=$O/$n.json > $O/$n.log 2>&1
  echo "$n: $(grep -o 'tw2_probe: .*' $O/$n.log) | $(grep -o 'air_model: .*' $O/$n.log | tail -1 | cut -c1-300)"
done
git checkout -- project.godot 2>/dev/null || true
