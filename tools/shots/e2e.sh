#!/usr/bin/env bash
# 12-02: 2 кадра на локацию (полёт в кабине + экран итога), локации — из configs/locations/*.json
# (не хардкод). Кадр — tools/shots/e2e_shot.tscn (та же цепочка меню→«Полёт…»→«Лететь»→разбег→
# полёт→посадка, что и tests/game/test_e2e.gd, но с настоящим рендером).
# tools/shots/e2e.sh [выход]   (по умолчанию docs/screenshots/e2e)
set -uo pipefail
cd "$(dirname "$0")/../.."

out="${1:-docs/screenshots/e2e}"
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"
fail=0

for f in configs/locations/*.json; do
	loc="$(basename "$f" .json)"
	echo "-- $loc --"
	timeout 120 godot --path . --audio-driver Dummy --resolution 1920x1080 \
		res://tools/shots/e2e_shot.tscn -- "--location=$loc" "--out=$out" || fail=1
done

echo
if [[ $fail == 0 ]]; then
	echo "e2e.sh: готово, кадры в $out"
else
	echo "e2e.sh: есть ошибки — см. вывод выше"
fi
exit $fail
