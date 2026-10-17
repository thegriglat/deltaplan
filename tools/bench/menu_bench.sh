#!/usr/bin/env bash
# Замер старта по LM-K1 (docs/contracts/live-menu.md): варианты main и proto (--live-menu-proto),
# на каждый — один временный профиль и дисковый кеш шейдеров, прогон 1 холодный, остальные тёплые.
#   tools/bench/menu_bench.sh [бинарник] [секунд полёта] [прогонов на вариант] [секунд окна меню]
# Итог — tools/research/live_menu/startup.json; сырые строки PERF — tools/research/live_menu/raw/.
# Нужен настоящий дисплей (DISPLAY=:0).
set -uo pipefail
cd "$(dirname "$0")/../.."

bin="${1:-build/linux/deltaplan.x86_64}"
secs="${2:-20}"
runs="${3:-3}"
win="${4:-40}"
export DISPLAY="${DISPLAY:-:0}"
out_dir=tools/research/live_menu
raw="$out_dir/raw"
mkdir -p "$raw"
rm -f "$raw"/*
build=$(git rev-parse --short HEAD)

for variant in main proto; do
	prof=$(mktemp -d)
	drv=$(mktemp -d)
	export XDG_DATA_HOME="$prof"
	export __GL_SHADER_DISK_CACHE_PATH="$drv" MESA_SHADER_CACHE_DIR="$drv"
	extra=()
	[[ $variant == proto ]] && extra=(--live-menu-proto)
	for i in $(seq 1 "$runs"); do
		t0=$(date +%s.%N)
		echo "$t0" > "$raw/$variant-$i.t0"; cut -d" " -f1-3 /proc/loadavg > "$raw/$variant-$i.load"
		timeout $((win + secs + 400)) stdbuf -oL "$bin" --audio-driver Dummy --resolution 1920x1080 -- \
			"${extra[@]}" "--perf-menu=$win" "--perf=$secs" > "$raw/$variant-$i.full" 2>&1
		echo "== $variant прогон $i: код $?"
		grep -E "^PERF |SCRIPT ERROR|^ERROR|запечённое" "$raw/$variant-$i.full" | grep -v "NO GRAB" > "$raw/$variant-$i.log"
		tail -25 "$raw/$variant-$i.full" | grep -v "^HTTP" > "$raw/$variant-$i.tail"
		rm -f "$raw/$variant-$i.full"
	done
	rm -rf "$prof" "$drv"
done
python3 "$out_dir/collect_startup.py" "$raw" "$build" "$out_dir/startup.json.tmp" \
	&& mv "$out_dir/startup.json.tmp" "$out_dir/startup.json"
python3 "$out_dir/check_startup_json.py" "$out_dir/startup.json"
