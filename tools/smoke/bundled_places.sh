#!/usr/bin/env bash
# Smoke встроенных мест из собранного каталога (tools/build.sh linux): для каждого старта —
# запуск бинарника с чистым профилем, место из pck, OSM-тайлы из pck, запечённое поле из pck, без сети.
# Итог — build/smoke/VI-12/smoke.txt: две строки на место: '<место> baked_from_pck=K/4 net_requests=M load_s=…' и '<место> osm_tiles_ok=N'
# Использование: tools/smoke/bundled_places.sh [каталог_сборки=build/linux] [время_полёта_с=6]
set -uo pipefail
cd "$(dirname "$0")/../.."
dir="${1:-build/linux}"
ft="${2:-6}"
out=build/smoke/VI-12
mkdir -p "$out"
: > "$out/smoke.txt"
export DISPLAY="${DISPLAY:-:0}"
declare -A SITES=(
	[volcano_island]="east_cliffs crater_ridge thermal_slope plateau_landing"
	[training_island]="ridge_west thermal_plain landing_hill lee_bowl"
)
for place in volcano_island training_island; do
	baked=0; osm=0; net=0; loadsum=0; loaded=0; wind_stage=0; warn=0
	for site in ${SITES[$place]}; do
		log="$out/$place-$site.log"
		prof=$(mktemp -d)
		XDG_DATA_HOME="$prof" timeout 240 "$dir/deltaplan.x86_64" --audio-driver Dummy -- \
			--autostart --location="$place" --site="$site" --bots=0 --time="$ft" \
			--screenshot="$out/$place-$site.png" >"$log" 2>&1
		rm -rf "$prof"
		grep -q "air_model: запечённое поле res://" "$log" && baked=$((baked + 1))
		t=$(grep -oE "Terrain: (место|локация) '?$place'? загружен[оа] за [0-9.]+" "$log" | grep -oE "[0-9.]+$" | head -1)
		[[ -n "$t" ]] && { loaded=$((loaded + 1)); loadsum=$(echo "$loadsum + $t" | bc -l); }
		o=$(grep -o "OSM тайлов [0-9]*/" "$log" | head -1 | grep -o "[0-9]*")
		osm=$((osm + ${o:-0}))
		net=$((net + $(grep -v "godotengine.org" "$log" | grep -ciE "HTTPRequest|http://|https://|LocationBuilder|OsmTilesStage|Overpass|скачива|сборка места")))
		grep -q "Рассчитываем ветер" "$log" && wind_stage=$((wind_stage + 1))
		warn=$((warn + $(grep -c "запечённое поле не берётся\|не прочиталось" "$log")))
	done
	[[ $loaded -gt 0 ]] || loaded=0
	avg=$(echo "scale=2; $loadsum / ${loaded/#0/1}" | bc -l)
	echo "$place baked_from_pck=$baked/4 net_requests=$net load_s=$avg loaded=$loaded/4 baked_refused=$warn" >> "$out/smoke.txt"
	echo "$place osm_tiles_ok=$osm (сумма по 4 стартам; 0 — у места нет OSM)" >> "$out/smoke.txt"
done
cat "$out/smoke.txt"
