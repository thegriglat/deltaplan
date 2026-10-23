#!/usr/bin/env bash
# SNW-5: один запуск snow_bench. run.sh <метка> <on|off> <lat,lon старта> <game-args через запятую> <poses> [shotdir]
# on — конфиг репозитория (или CFG_OVERRIDE=<файл>); off — пользовательская копия configs/snow_plume.json с enabled=false.
# Запускать под замком: .dpcli/dpcli lock cpu <ID> -- <путь>/run.sh … (+ lock gpu для замера кадра), ждать .dpcli/dpcli job wait <ID> <с>.
set -uo pipefail
cd "$(dirname "$0")/../../../.."
tag=$1; mode=$2; latlon=$3; gargs=$4; poses=$5; shotdir=${6:-}
export XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}
export DISPLAY=${DISPLAY:-:0}
cfgd=$XDG_DATA_HOME/Deltaplan/configs
mkdir -p "$cfgd"
if [[ $mode == off ]]; then
	python3 - "$cfgd/snow_plume.json" <<'PY'
import json, sys
c = json.load(open("configs/snow_plume.json"))
c["enabled"] = False
json.dump(c, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
PY
else
	rm -f "$cfgd/snow_plume.json"
	[[ -n ${CFG_OVERRIDE:-} ]] && cp "$CFG_OVERRIDE" "$cfgd/snow_plume.json"
fi
out=${OUT_DIR:-tools/research/snow_plume/SNW-5/data}
mkdir -p "$out"
rm -f "$out/$tag.jsonl"
timeout 900 godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
	res://tools/research/snow_plume/SNW-5/snow_bench.tscn -- --latlon="$latlon" --out="$out/$tag.jsonl" \
	--game-args="$gargs" --poses="$poses" ${shotdir:+--shotdir="$shotdir"} >"$out/$tag.log" 2>&1
echo "$tag exit=$?"; grep -E "^snow_bench:|SCRIPT ERROR" "$out/$tag.log" | cut -c1-600
