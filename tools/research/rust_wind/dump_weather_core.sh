#!/usr/bin/env bash
# RW-6c: дамп погоды и солнца для поля (эталон GDScript) → rust/dp-air/tests/data/weather_core/.
#   tools/research/rust_wind/dump_weather_core.sh [--out=<каталог>]   пересъёмка
#   tools/research/rust_wind/dump_weather_core.sh --verify            во временный каталог и побитное сравнение
# Godot — под замком cpu снаружи (.dpcli/dpcli lock cpu <имя> -- …; accept ставит в очередь сам).
set -uo pipefail
cd "$(dirname "$0")/../../.."

ref=rust/dp-air/tests/data/weather_core
verify=0
args=()
for a in "$@"; do
	if [ "$a" = "--verify" ]; then verify=1; else args+=("$a"); fi
done
out=""
if [ "$verify" = 1 ]; then
	out="$(mktemp -d)"
	args+=("--out=$out")
fi

profile="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}"
mkdir -p "$profile"
pg_backup="$(mktemp)"
cp project.godot "$pg_backup"
scene="$(mktemp --suffix=.tscn)"
cat >"$scene" <<'T'
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tools/research/rust_wind/dump_weather_core.gd" id="1"]

[node name="DumpWeatherCore" type="Node"]
script = ExtResource("1")
T
trap 'cmp -s project.godot "$pg_backup" || cp "$pg_backup" project.godot; rm -f "$pg_backup" "$scene"; [ -n "$out" ] && rm -rf "$out"' EXIT

[ -d .godot ] || XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
log="$(mktemp)"
if ! XDG_DATA_HOME="$profile" godot --headless --path . "$scene" -- "${args[@]}" >"$log" 2>&1; then
	tail -30 "$log"
	rm -f "$log"
	echo "dump_weather_core: Godot упал"
	exit 2
fi
if grep -q "SCRIPT ERROR\|ERROR:" "$log"; then
	grep "SCRIPT ERROR\|ERROR:" "$log" | head -20
	rm -f "$log"
	echo "dump_weather_core: ошибки в журнале Godot"
	exit 2
fi
rm -f "$log"
[ "$verify" = 1 ] || exit 0

bad=0
for f in $(cd "$out" && find . -type f | sort); do
	cmp -s "$out/$f" "$ref/$f" || { echo "verify: расходится $f"; bad=1; }
done
for f in $(cd "$ref" && find . -type f | sort); do
	[ -e "$out/$f" ] || { echo "verify: нет в пересъёмке $f"; bad=1; }
done
[ "$bad" = 0 ] && echo "verify: дамп воспроизводится побитно"
exit "$bad"
