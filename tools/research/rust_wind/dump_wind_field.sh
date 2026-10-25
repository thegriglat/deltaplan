#!/usr/bin/env bash
# RW-6i: дамп поля воздуха (WindField, AirFieldSet; эталон GDScript) → rust/dp-air/tests/data/wind_field/.
#   tools/research/rust_wind/dump_wind_field.sh [--out=<каталог>]   пересъёмка
#   tools/research/rust_wind/dump_wind_field.sh --verify            во временный каталог и побитное сравнение
# Godot — под замком cpu снаружи (.dpcli/dpcli lock cpu <имя> -- …; accept ставит в очередь сам).
set -uo pipefail
cd "$(dirname "$0")/../../.."

ref=rust/dp-air/tests/data/wind_field
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

# Состояния Пикара R4 (вне git): нет — пересчитать готовым picard_rs (release).
data="${DP_AIR_DATA:-$HOME/data/air_cascade}"
if [ ! -e "$data/rw6i/u3_heat.json" ] || [ ! -e "$data/rw6i/u3_mech.json" ]; then
	echo "dump_wind_field: нет состояний R4 в $data/rw6i — решаю Пикаром (несколько минут)"
	cargo build -q --release --manifest-path rust/Cargo.toml -p picard_rs || exit 2
	mkdir -p "$data/rw6i"
	for c in heat mech; do
		rust/target/release/picard solve "$data/ongudai/ongudai_d400_u3_$c.json" --threads 4 \
			--tol-scale 5 --save-state "$data/rw6i/u3_$c.json" --out "$data/rw6i/u3_${c}_r2.json" \
			>/dev/null || exit 2
	done
fi

profile="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}"
mkdir -p "$profile"
pg_backup="$(mktemp)"
cp project.godot "$pg_backup"
scene="$(mktemp --suffix=.tscn)"
cat >"$scene" <<'T'
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tools/research/rust_wind/dump_wind_field.gd" id="1"]

[node name="DumpWindField" type="Node"]
script = ExtResource("1")
T
trap 'cmp -s project.godot "$pg_backup" || cp "$pg_backup" project.godot; rm -f "$pg_backup" "$scene"; [ -n "$out" ] && rm -rf "$out"' EXIT

[ -d .godot ] || XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
log="$(mktemp)"
if ! XDG_DATA_HOME="$profile" timeout 900 godot --headless --path . "$scene" -- "${args[@]}" >"$log" 2>&1; then
	tail -30 "$log"
	rm -f "$log"
	echo "dump_wind_field: Godot упал"
	exit 2
fi
# без собранной библиотеки dp_air (addons/dp_air/bin) Godot жалуется на расширение — к дампу не относится
errs="$(grep "SCRIPT ERROR\|ERROR:" "$log" | grep -v "dp_air\|open_dynamic_library\|open_library\|load_extensions" || true)"
if [ -n "$errs" ]; then
	echo "$errs" | head -20
	rm -f "$log"
	echo "dump_wind_field: ошибки в журнале Godot"
	exit 2
fi
rm -f "$log"
[ "$verify" = 1 ] || exit 0

bad=0
for f in $(cd "$out" && find . -type f | sort); do
	cmp -s "$out/$f" "$ref/$f" || { echo "verify: расходится $f"; bad=1; }
done
for f in $(cd "$ref" && find . -type f ! -name README.md | sort); do
	[ -e "$out/$f" ] || { echo "verify: нет в пересъёмке $f"; bad=1; }
done
[ "$bad" = 0 ] && echo "verify: дамп воспроизводится побитно"
exit "$bad"
