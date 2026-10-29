#!/usr/bin/env bash
# Эталоны RW-12d из Godot: rust/dp-air/tests/data/RW-12d/weather_ref.sh [--out=<каталог>]
# Выход: climate_cells.json (loc.climate_cell/_lag мест) и <случай>.weather.json (cases/). Снимать на опорной
# ревизии c591b1026 (git worktree add <scratch>/gd-ref c591b1026) под замком cpu:
#   .dpcli/dpcli lock cpu <имя> -- rust/dp-air/tests/data/RW-12d/weather_ref.sh --out=<каталог>
# Headless, временный профиль, project.godot возвращается как был.
set -uo pipefail
cd "$(dirname "$0")/../../../../.."
out="$PWD/rust/dp-air/tests/data/RW-12d/out"
for a in "$@"; do
	case "$a" in --out=*) out="$(realpath -m "${a#--out=}")" ;; esac
done
tmp="$(mktemp -d)"
profile="$tmp/profile"
mkdir -p "$profile"
cp project.godot "$tmp/project.godot.bak"
trap 'cmp -s project.godot "$tmp/project.godot.bak" || cp "$tmp/project.godot.bak" project.godot; rm -rf "$tmp"' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
log="$tmp/godot.log"
if ! XDG_DATA_HOME="$profile" timeout 900 godot --headless --path . res://rust/dp-air/tests/data/RW-12d/weather_ref.tscn -- "--out=$out" >"$log" 2>&1; then
	tail -30 "$log"
	echo "weather_ref: Godot упал"
	exit 2
fi
if grep -q "SCRIPT ERROR" "$log"; then
	grep "SCRIPT ERROR" "$log" | head -20
	echo "weather_ref: ошибки сценария"
	exit 2
fi
ls "$out"
