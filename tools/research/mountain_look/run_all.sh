#!/usr/bin/env bash
# Прогон зонда MLK-К3 по плану мест. Использование: run_all.sh [тег …] (без аргументов — все).
# Кеш сырых данных и мест: $MLK_CACHE (по умолчанию ~/projects/.tmp/mlk_cache), НЕ профиль пилота.
set -u
cd "$(dirname "$0")/../../.."
CACHE=${MLK_CACHE:-$HOME/projects/.tmp/mlk_cache}
OUT=tools/research/mountain_look/data
EV="27.9881,86.925,Everest;27.9617,86.933,Lhotse;27.965,86.886,Nuptse;27.8617,86.8614,AmaDablam;27.8897,87.0886,Makalu"
declare -A LL=(
 [everest_namche]="27.805,86.714" [everest_gokyo]="27.95,86.69" [everest_menu]="27.9957,86.8285"
 [elbrus_cheget]="43.26,42.52" [elbrus_menu]="43.245,42.51"
 [montblanc_chamonix]="45.9335,6.8795" [dombay]="43.28,41.63")
declare -A TG=(
 [everest_namche]="$EV" [everest_gokyo]="$EV" [everest_menu]="$EV"
 [elbrus_cheget]="43.3499,42.4453,Elbrus" [elbrus_menu]="43.3499,42.4453,Elbrus"
 [montblanc_chamonix]="45.8326,6.8652,MontBlanc;45.9333,6.9683,AiguilleVerte"
 [dombay]="43.2417,41.7403,DombayUlgen")
tags=("$@"); [ ${#tags[@]} -eq 0 ] && tags=(ongudai everest_namche everest_gokyo everest_menu elbrus_cheget elbrus_menu montblanc_chamonix dombay)
for tag in "${tags[@]}"; do
  args=(--tag=$tag --out=$OUT/before_$tag.json --cache=$CACHE)
  if [ "$tag" = ongudai ]; then args+=(--location=ongudai); else args+=(--latlon=${LL[$tag]} "--targets=${TG[$tag]}"); fi
  XDG_DATA_HOME=$(mktemp -d) systemd-run --user --scope -q -p MemoryMax=12G \
    godot --headless --path . res://tools/bench/mountain_look_probe.tscn -- "${args[@]}" > $OUT/before_$tag.log 2>&1
  tail -1 $OUT/before_$tag.log
done
