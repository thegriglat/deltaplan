#!/usr/bin/env bash
# SP-1: пачка замеров пересчёта в полёте (flight_probe) под одним замком GPU.
#   tools/research/air_speed/run_flight.sh [имя:вариант:разрешение …]
# По умолчанию — base 1280×720 и 320×240, slice8/slice16/gapoff 1280×720. Готовые (out/<имя>.json
# есть) пропускаются — продолжение с места. nvidia-smi до и после каждого — в out/<имя>.gpu.txt.
set -uo pipefail
cd "$(dirname "$0")/../../.."
out=tools/research/air_speed/out
mkdir -p "$out"
plan=("$@")
[ ${#plan[@]} -gt 0 ] || plan=(
	"flight_base_1280:base:1280x720"
	"flight_base_320:base:320x240"
	"flight_slice8_1280:slice8:1280x720"
	"flight_slice16_1280:slice16:1280x720"
	"flight_gapoff_1280:gapoff:1280x720"
)
pg_backup="$(mktemp)"
cp project.godot "$pg_backup"
trap 'cmp -s project.godot "$pg_backup" || cp "$pg_backup" project.godot; rm -f "$pg_backup"' EXIT
exec 9>/tmp/heat_ca_gpu.lock
echo "ждём замок GPU…"
flock -w 3600 9 || { echo "замок не получен"; exit 1; }
for item in "${plan[@]}"; do
	IFS=: read -r name variant res <<<"$item"
	[ -f "$out/$name.json" ] && { echo "$name: уже есть"; continue; }
	{
		date -Is
		nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader
		nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader
	} >"$out/$name.gpu.txt"
	echo "$name ($variant, $res)…"
	XDG_DATA_HOME="$(mktemp -d)" timeout 900 godot --path . --audio-driver Dummy --resolution "$res" \
		res://tools/research/air_speed/flight_probe.tscn -- --variant="$variant" --win="$res" --runs=3 \
		--out="$out/$name.json" >"$out/$name.log" 2>&1
	echo "  код $?"
	nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader >>"$out/$name.gpu.txt"
	cmp -s project.godot "$pg_backup" || cp "$pg_backup" project.godot
done
