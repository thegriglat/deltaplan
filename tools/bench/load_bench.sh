#!/usr/bin/env bash
# Замер времени загрузки (NFR-2, ≤ 10 с) на пресете medium (карточка
# docs/plan/build/03-zamery-fps-zagruzka.md). Для каждой локации configs/locations/*.json —
# tools/bench/probe.tscn --mode=load: время от старта скрипта пробы (движок уже поднят) до первого
# кадра полёта (FLYING), тёплый кеш .godot/ (запускается после import, обычно уже тёплый).
#   tools/bench/load_bench.sh [локация...]   (по умолчанию все локации)
# Нужен настоящий дисплей (DISPLAY=:0); каждый прогон — под timeout 120.
set -uo pipefail
cd "$(dirname "$0")/../.."

fail=0
export DISPLAY="${DISPLAY:-:0}"

echo "== пресет графики: medium =="
godot --headless --path . res://tools/bench/set_preset.tscn -- --preset=medium 2>&1 | grep -E "set_preset|ERROR" || true
echo "== прогрев .godot/ (импорт) =="
godot --headless --path . --import >/dev/null 2>&1 || true

locs=("$@")
if [[ ${#locs[@]} -eq 0 ]]; then
	locs=()
	for f in configs/locations/*.json; do
		locs+=("$(basename "$f" .json)")
	done
fi

echo
echo "Локация | время загрузки"
echo "--- | ---"
for loc in "${locs[@]}"; do
	out=$(timeout 120 godot --path . --audio-driver Dummy --disable-vsync --fullscreen \
		--resolution 1920x1080 res://tools/bench/probe.tscn -- \
		"--location=$loc" --mode=load 2>&1)
	line=$(echo "$out" | grep -E "^LOAD " || true)
	if [[ -n $line ]]; then
		echo "$line" | sed -E 's/^LOAD ([^:]+): (.*)/\1 | \2/'
		secs=$(echo "$line" | sed -E 's/^LOAD [^:]+: ([0-9.]+).*/\1/')
		awk -v s="$secs" 'BEGIN{exit !(s>10)}' && echo "  (!) $loc: $secs с > 10 с (NFR-2)"
	else
		echo "$loc | ОШИБКА"
		echo "$out" >&2
		fail=1
	fi
done

exit $fail
