#!/usr/bin/env bash
# Полёты за гребнем LT-14. Из корня копии задачи:
#   run.sh fly   <code> <корень_копии> <seed>          headless, строки проходов -> out/raw/flights_<code>_s<seed>.csv
#   run.sh frame <code> <корень_копии> <seed>          окно 1920x1080, пресет medium, ЗАМОК GPU -> out/raw/frame_<code>.csv
#   run.sh merge                                        out/raw/* -> out/flights.csv, out/frame_time.csv
# code: old (временная копия `git worktree add --detach <каталог> 7665fb7`, в ней tools/build_rust.sh release linux)
#       | new (копия задачи). Скрипт полёта копируется в корень копии кода (в git чужой копии не коммитится).
# Профиль Godot — постоянный профиль копии (в нём собранное место ongudai, кеш воздуха): ~/.cache/dp-xdg/<имя копии>.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TASK=$(cd "$HERE/../../../.." && pwd)
RAW=$HERE/out/raw
mkdir -p "$RAW"
mode=${1:?fly|frame|merge}
if [[ "$mode" == merge ]]; then
	python3 -I "$HERE/merge.py" "$HERE/out"
	exit 0
fi
code=${2:?old|new}; root=$(cd "${3:?корень копии}" && pwd); seed=${4:-1}; shift 4 || shift $#
if [[ "$root" != "$TASK" ]]; then
	mkdir -p "$root/tools/research/lee_turb/flight"
	cp "$HERE/lee_pass.gd" "$HERE/lee_pass.tscn" "$root/tools/research/lee_turb/flight/"
fi
prof=${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$root")}
cd "$root"
case "$mode" in
fly)
	XDG_DATA_HOME="$prof" godot --headless --path . --audio-driver Dummy \
		res://tools/research/lee_turb/flight/lee_pass.tscn -- --code="$code" --seed="$seed" \
		--out="$RAW/flights_${code}_s${seed}.csv" "$@"
	;;
frame)
	export DISPLAY="${DISPLAY:-:0}"
	XDG_DATA_HOME="$prof" godot --headless --path . res://tools/bench/set_preset.tscn -- --preset=medium 2>&1 | grep -E "set_preset|ERROR" || true
	XDG_DATA_HOME="$prof" timeout 3000 godot --path . --audio-driver Dummy --disable-vsync --resolution 1920x1080 \
		res://tools/research/lee_turb/flight/lee_pass.tscn -- --code="$code" --seed="$seed" --frame=1 \
		--passes=40:0:2 --repeat=3 --out="$RAW/frame_${code}.csv" "$@"
	git checkout -- project.godot 2>/dev/null || true
	;;
esac
