#!/usr/bin/env bash
# RW-6n: дамп окон клипмапа 100/50 м из GDScript и GPU игры в rust/dp-air/tests/data/window/.
#   dump_window.sh            — снять и записать в tests/data
#   dump_window.sh --verify   — снять во временный каталог и сравнить: CPU-часть (inputs.*) побитно,
#                               GPU-часть (gpu.*) в допусках (итерации ±max(20, iters/10), массивы
#                               ≤ 1e-4 от масштаба; сравнивает сам дампер, --ref)
# Нужен настоящий RenderingDevice: Godot НЕ headless (маленькое окно, как tools/gpu_tests.sh),
# вызывать под замком: .dpcli/dpcli lock gpu <имя> -- tools/research/rust_wind/dump_window.sh
set -uo pipefail
cd "$(dirname "$0")/../../.."
ref=rust/dp-air/tests/data/window
verify=0
[ "${1:-}" = "--verify" ] && verify=1
profile="$(mktemp -d)"
pg_backup="$profile/project.godot.bak"
cp project.godot "$pg_backup"
scene="$PWD/tools/research/rust_wind/dump_window.tscn"
trap 'cmp -s project.godot "$pg_backup" || cp "$pg_backup" project.godot; rm -rf "$profile"' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
if [ "$verify" = 1 ]; then
	out="$profile/out"
	extra="--ref=$PWD/$ref"
else
	out="$PWD/$ref"
	extra=""
fi
mkdir -p "$out"
XDG_DATA_HOME="$profile" timeout 900 godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
	"$scene" -- --out="$out" $extra >"$profile/run.log" 2>&1
status=$?
grep -E "^(dump_window|verify):" "$profile/run.log"
grep -q "SCRIPT ERROR" "$profile/run.log" && { grep -A3 "SCRIPT ERROR" "$profile/run.log" | head -30; echo "dump_window: ошибки скрипта"; exit 2; }
if [ "$status" != 0 ]; then
	tail -30 "$profile/run.log"
	echo "dump_window: дампер завершился с кодом $status"
	exit 2
fi
[ "$verify" = 1 ] || { echo "dump_window: записано в $ref"; exit 0; }
bad=0
for f in inputs.json inputs.bin; do
	cmp -s "$out/$f" "$ref/$f" || { echo "verify: расходится $f"; bad=1; }
done
[ "$bad" = 0 ] && echo "verify: CPU-часть воспроизводится побитно, GPU-часть — в допусках"
exit "$bad"
