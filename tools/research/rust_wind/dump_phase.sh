#!/usr/bin/env bash
# RW-6k: дамп фаз поля из GDScript (AirPhase) в rust/dp-air/tests/data/phase/.
#   dump_phase.sh            — снять и записать в tests/data
#   dump_phase.sh --verify   — снять во временный каталог и сравнить побитно с tests/data
# Godot тяжёлый — вызывать под замком: .dpcli/dpcli lock cpu <имя> -- tools/research/rust_wind/dump_phase.sh
set -uo pipefail
cd "$(dirname "$0")/../../.."
ref=rust/dp-air/tests/data/phase
verify=0
[ "${1:-}" = "--verify" ] && verify=1
profile="$(mktemp -d)"
pg_backup="$profile/project.godot.bak"
cp project.godot "$pg_backup"
scene="$(mktemp --suffix=.tscn)"
cat >"$scene" <<'T'
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tools/research/rust_wind/dump_phase.gd" id="1"]

[node name="DumpFieldInput" type="Node"]
script = ExtResource("1")
T
trap 'rm -f "$scene"; cmp -s project.godot "$pg_backup" || cp "$pg_backup" project.godot; rm -rf "$profile"' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
if [ "$verify" = 1 ]; then
	out="$profile/out"
else
	out="$PWD/$ref"
fi
mkdir -p "$out"
XDG_DATA_HOME="$profile" timeout 600 godot --headless --path . "$scene" -- --out="$out" \
	>"$profile/run.log" 2>&1 || { tail -30 "$profile/run.log"; echo "dump_phase: дампер упал"; exit 2; }
grep -q "SCRIPT ERROR" "$profile/run.log" && { grep -A2 "SCRIPT ERROR" "$profile/run.log" | head -20; echo "dump_phase: ошибки скрипта"; exit 2; }
[ "$verify" = 1 ] || { echo "dump_phase: записано в $ref"; exit 0; }
bad=0
for f in $(cd "$out" && ls); do
	cmp -s "$out/$f" "$ref/$f" || { echo "verify: расходится $f"; bad=1; }
done
for f in $(cd "$ref" && ls); do
	[ -e "$out/$f" ] || { echo "verify: нет в пересъёмке $f"; bad=1; }
done
[ "$bad" = 0 ] && echo "verify: дамп воспроизводится побитно"
exit "$bad"
