#!/usr/bin/env bash
# Замер FPS (NFR-1) на пресете medium (карточка docs/archive/plan/build/03-zamery-fps-zagruzka.md).
# Для каждой локации configs/locations/*.json один прогон tools/bench/probe.tscn (--autopilot):
# на трёх отметках симуляционного времени полёта (старт у склона, высота над лесом, вид на облака)
# сэмплирует камеры "кабина" и "сзади" по --sample= с, печатает средний и 1%-low FPS.
#   tools/bench/frame_bench.sh [локация...]   (по умолчанию все локации)
# Нужен настоящий дисплей (DISPLAY=:0); WM режет окна плиткой — берём --fullscreen --resolution и
# --disable-vsync (иначе FPS упирается в частоту монитора). Каждый прогон — под timeout 120.
set -uo pipefail
cd "$(dirname "$0")/../.."

fail=0
export DISPLAY="${DISPLAY:-:0}"

echo "== пресет графики: medium =="
godot --headless --path . res://tools/bench/set_preset.tscn -- --preset=medium 2>&1 | grep -E "set_preset|ERROR" || true

locs=("$@")
if [[ ${#locs[@]} -eq 0 ]]; then
	locs=()
	for f in configs/locations/*.json; do
		locs+=("$(basename "$f" .json)")
	done
fi

# Отметки, с сим.времени полёта: старт у склона, высота над лесом, вид на облака.
MARKS="2:cockpit,2:chase,30:cockpit,30:chase,60:cockpit,60:chase"
SAMPLE_S=4

echo
echo "Локация | Ракурс@отметка | средний FPS | 1%-low FPS"
echo "--- | --- | --- | ---"
for loc in "${locs[@]}"; do
	out=$(timeout 120 godot --path . --audio-driver Dummy --disable-vsync --fullscreen \
		--resolution 1920x1080 res://tools/bench/probe.tscn -- \
		"--location=$loc" "--marks=$MARKS" "--sample=$SAMPLE_S" 2>&1)
	echo "$out" | grep -E "^BENCH " | sed -E \
		's/^BENCH ([^ ]+) ([a-z]+)@([0-9.]+)с: avg=([0-9.]+) fps 1%low=([0-9.]+) fps.*/\1 | \2@\3с | \4 | \5/'
	if echo "$out" | grep -q "^probe: FAIL"; then
		echo "$loc | — | ОШИБКА | $(echo "$out" | grep '^probe: FAIL')"
		fail=1
	fi
	if ! echo "$out" | grep -q "^probe: OK"; then
		echo "$loc | — | ОШИБКА | нет OK в выводе"
		echo "$out" >&2
		fail=1
	fi
done

exit $fail
