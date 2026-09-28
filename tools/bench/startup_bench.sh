#!/usr/bin/env bash
# Замер старта собранной игры (то, что запускает пилот): время до меню, «Лететь» → первый кадр
# полёта, рывки кадра > 50 мс за первые <с> полёта, сборка compute-шейдеров облаков (без кеша: каждый запуск).
#   tools/bench/startup_bench.sh [бинарник] [секунд полёта] [прогонов]
# По умолчанию build/linux/deltaplan.x86_64 (tools/build.sh linux --release), 60 с, 2 прогона.
# Один профиль на серию: первый прогон — холодный (пустой user://: кеши шейдеров Godot, пайплайнов,
# пустой дисковый кеш драйвера NVIDIA/Mesa), дальше — тёплые.
# Грозовой день (--temp=34), старт в воздухе с автопилотом — в кадре Cb и дождь.
# Нужен настоящий дисплей (DISPLAY=:0).
set -uo pipefail
cd "$(dirname "$0")/../.."

bin="${1:-build/linux/deltaplan.x86_64}"
secs="${2:-60}"
runs="${3:-2}"
export DISPLAY="${DISPLAY:-:0}"

prof=$(mktemp -d)
drv=$(mktemp -d)
trap 'rm -rf "$prof" "$drv"' EXIT
export XDG_DATA_HOME="$prof"
export __GL_SHADER_DISK_CACHE_PATH="$drv" MESA_SHADER_CACHE_DIR="$drv"

for i in $(seq 1 "$runs"); do
	kind=$([[ $i == 1 ]] && echo холодный || echo тёплый)
	t0=$(date +%s.%N)
	out=$(timeout $((secs + 150)) stdbuf -oL "$bin" --audio-driver Dummy --resolution 1920x1080 -- \
		--temp=34 --air-start --autopilot "--perf=$secs" 2>&1)
	code=$?
	menu_unix=$(echo "$out" | sed -nE 's/^PERF menu_ms=[0-9]+ unix=([0-9.]+).*/\1/p')
	menu_s=$(awk -v a="$t0" -v b="$menu_unix" 'BEGIN{ if (b == "") print "?"; else printf "%.2f", b - a }')
	echo "== прогон $i ($kind): до меню ${menu_s} с (от запуска процесса)"
	echo "$out" | grep -E "^PERF |SCRIPT ERROR|^ERROR" | grep -v "NO GRAB" | sed 's/^/  /'
	if ! echo "$out" | grep -q "^PERF cloud"; then
		echo "  (!) нет итога, код выхода $code; хвост вывода:"
		echo "$out" | tail -15 | sed 's/^/    /'
	fi
done
