#!/bin/bash
# Поля у стартов до/после ограничения k (fix/lee-start-calibration): run.sh <метка> [имя…]
# Пишет out/<метка>/<имя>.json (сетка ±2,4 км, 30/100/200 м над землёй) и .log (строка air_model с k).
# Под замком GPU: .dpcli/dpcli job start <имя> 3600 --lock gpu tools/research/lee_cal/run.sh before
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"; cd "$ROOT" || exit 2
export XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$ROOT")}
TAG=${1:?метка}; shift
O=$HERE/out/$TAG; mkdir -p "$O"
declare -A A=(
 [anakena]="--latlon=-27.07572,-109.32200 --from=110"
 [ranokau_ne]="--latlon=-27.16295,-109.40859 --from=110"
 [terevaka_s]="--latlon=-27.11349,-109.38031 --from=110"
 [cand4]="--latlon=-27.13372,-109.37677 --from=110"
 [cand2]="--latlon=-27.10495,-109.23837 --from=110"
 [poike_e]="--latlon=-27.10000,-109.23383 --from=110"
 [ongudai]="--location=ongudai --site=kayancha_south --from=151"
 [ongudai_back]="--location=ongudai --site=kayancha_south --from=331"
 [askarovo_w]="--location=askarovo --site=biyagoda_west --from=294"
 [askarovo_e]="--location=askarovo --site=biyagoda_east --from=94"
)
NAMES=("$@"); [ ${#NAMES[@]} -eq 0 ] && NAMES=(anakena ranokau_ne terevaka_s cand4 cand2 poike_e ongudai ongudai_back askarovo_w askarovo_e)
for n in "${NAMES[@]}"; do
  DISPLAY="${DISPLAY:-:0}" timeout 900 godot --path . --audio-driver Dummy --resolution 320x240 res://tools/research/lee_cal/air_scan.tscn -- \
    --autostart ${A[$n]} --wind=6 --air-start=0,100 --hour=12 --bots=0 --out=$O/$n.json --R=2400 --step=100 > $O/$n.log 2>&1
  echo "$n: $(grep -o 'air_scan: .*' $O/$n.log)"
done
git checkout -- project.godot 2>/dev/null || true
