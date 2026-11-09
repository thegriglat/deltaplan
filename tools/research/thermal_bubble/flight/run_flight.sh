#!/usr/bin/env bash
# Полётный замер термиков TB-14 (контракт TB5 v1). Из корня копии.
#   run_flight.sh probe <tag> <0|1> [доп. аргументы flight_probe]   headless: присутствие, приток, ядро, разрывы
#   run_flight.sh frame <tag> <0|1> [доп. аргументы flight_frame]   дисплей, ЗАМОК GPU: время кадра, пресет medium
#   run_flight.sh summary <tag>                                      сводка out/flight_<tag>.json
# Флаг 0 — шаблон выкл (r2_old), 1 — вкл (r2_new). Сырьё — build/flight/<tag>_{probe,frame}.json.
# Профиль Godot для probe — постоянный профиль копии (в нём собранное место ongudai);
# для frame — временный: symlink на места и кеш воздуха (air_cache), пресет medium, user://configs/atmosphere.json с флагом.
# frame вызывать под замком: .dpcli/dpcli job start --lock gpu <имя> <таймаут> tools/research/thermal_bubble/flight/run_flight.sh frame …
set -euo pipefail
cd "$(dirname "$0")/../../../.."
mode=${1:?probe|frame|summary}; tag=${2:?tag}
raw=build/flight
mkdir -p "$raw" tools/research/thermal_bubble/out
persist=${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}
case "$mode" in
probe)
	flag=${3:?0|1}; shift 3
	export DISPLAY="${DISPLAY:-:0}"
	XDG_DATA_HOME="$persist" godot --path . --audio-driver Dummy --disable-vsync --resolution 320x240 \
		res://tools/research/thermal_bubble/flight/flight_probe.tscn -- \
		--bubble="$flag" --out="$raw/${tag}_probe.json" "$@"
	;;
frame)
	flag=${3:?0|1}; shift 3
	export DISPLAY="${DISPLAY:-:0}"
	prof=$(mktemp -d)
	trap 'rm -rf "$prof"' EXIT
	mkdir -p "$prof/Deltaplan/configs"
	mkdir -p "$persist/Deltaplan/air_cache"
	ln -s "$persist/Deltaplan/locations" "$prof/Deltaplan/locations"
	ln -s "$persist/Deltaplan/air_cache" "$prof/Deltaplan/air_cache"
	b=false; [[ "$flag" == 1 ]] && b=true
	printf '{"thermal": {"bubble_template": %s}}\n' "$b" >"$prof/Deltaplan/configs/atmosphere.json"
	XDG_DATA_HOME="$prof" godot --headless --path . res://tools/bench/set_preset.tscn -- --preset=medium 2>&1 | grep -E "set_preset|ERROR" || true
	XDG_DATA_HOME="$prof" timeout 1200 godot --path . --audio-driver Dummy --disable-vsync \
		--resolution 1920x1080 res://tools/research/thermal_bubble/flight/flight_frame.tscn -- \
		--out="$raw/${tag}_frame.json" "$@"
	git checkout -- project.godot 2>/dev/null || true
	;;
summary)
	python3 tools/research/thermal_bubble/flight/flight_summary.py "$tag" \
		"$raw/${tag}_probe.json" "$raw/${tag}_frame.json" \
		"tools/research/thermal_bubble/out/flight_${tag}.json"
	;;
*) echo "режим: probe|frame|summary" >&2; exit 2 ;;
esac
