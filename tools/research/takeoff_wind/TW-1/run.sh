#!/bin/bash
# TW-1: пачка прогонов rec.tscn. Каждая строка задания — один процесс godot со своим временным
# профилем (XDG_DATA_HOME=$(mktemp -d)); параллельно P процессов.
#   run.sh <out_subdir> <P> <файл заданий>
# Строка задания: флаги rec.gd через пробел, например
#   --tw-flow=e2e --tw-locs=training_island --tw-seeds=1..10 --tw-ap=base --tw-air=field
# TW_GPU=1 — окно (поле воздуха на GPU, как в игре; запускать под .dpcli/dpcli lock gpu).
# Итог — out/<out_subdir>/runs.jsonl (строка на прогон), логи — out/<out_subdir>/logs/.
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../../.." && pwd)"; cd "$ROOT" || exit 2
SUB=${1:?out_subdir}; P=${2:-6}; JOBS=${3:?файл заданий}
O=$HERE/out/$SUB; mkdir -p "$O/logs"
cp project.godot "$O/.project.godot.bak"
trap 'cmp -s project.godot "$O/.project.godot.bak" || cp "$O/.project.godot.bak" project.godot; rm -f "$O/.project.godot.bak"' EXIT
n=0
while IFS= read -r line; do
	[[ -z "$line" || "$line" == \#* ]] && continue
	n=$((n+1))
	printf '%s\t%s\n' "$n" "$line"
done < "$JOBS" | xargs -P "$P" -d '\n' -I{} bash -c '
	id=$(cut -f1 <<<"$1"); args=$(cut -f2 <<<"$1")
	x=$(mktemp -d)
	# --tw-rollmode=rate|weight_shift — режим крена (FlightModel/GroundRun) через user://configs профиля
	rm_=$(grep -o -- "--tw-rollmode=[a-z_]*" <<<"$args" | cut -d= -f2)
	if [[ -n "$rm_" ]]; then mkdir -p "$x/Deltaplan/configs"; echo "{\"roll_control_mode\": \"$rm_\"}" > "$x/Deltaplan/configs/controls.json"; fi
	scene=$(grep -o -- "--tw-scene=[a-z_]*" <<<"$args" | cut -d= -f2); scene=${scene:-rec}
	mode=(--headless); [[ "${TW_GPU:-0}" == 1 ]] && mode=(--audio-driver Dummy --resolution 320x240)
	DISPLAY=${DISPLAY:-:0} XDG_DATA_HOME=$x timeout 5400 godot "${mode[@]}" --path . res://tools/research/takeoff_wind/TW-1/$scene.tscn -- \
		$args --tw-out="$2/part_$id" > "$2/logs/$id.log" 2>&1
	echo "job $id exit=$? $args"
	rm -rf "$x"
' _ {} "$O"
cat "$O"/part_*/runs.jsonl > "$O/runs.jsonl" 2>/dev/null
echo "runs: $(wc -l < "$O/runs.jsonl")"
