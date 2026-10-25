#!/usr/bin/env bash
# Генератор эталонов ветра (RW-1): tools/wind_fixtures/run.sh [--out=<каталог>] [--only=имя,имя] [--synthetic]
# Без --synthetic — окно (маленькое, GPU: поле Пикара Онгудая), временный профиль, project.godot
# возвращается как был. С --synthetic — headless, только синтетическое место (без GPU).
# Godot — под замком cpu (.dpcli/dpcli lock cpu <имя> -- tools/wind_fixtures/run.sh …); gpu-случаи
# вызывающий берёт отдельно, если нужно (verify.sh под accept ставится в очередь сам).
set -uo pipefail
cd "$(dirname "$0")/../.."

synthetic=0
for a in "$@"; do [ "$a" = "--synthetic" ] && synthetic=1; done

profile="$(mktemp -d)"
pg_backup="$profile/project.godot.bak"
cp project.godot "$pg_backup"
trap 'cmp -s project.godot "$pg_backup" || cp "$pg_backup" project.godot; rm -rf "$profile"' EXIT

XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
if [ "$synthetic" = 1 ]; then
	XDG_DATA_HOME="$profile" godot --headless --path . res://tools/wind_fixtures/gen_fixtures.tscn -- "$@"
else
	XDG_DATA_HOME="$profile" godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
		res://tools/wind_fixtures/gen_fixtures.tscn -- "$@"
fi
