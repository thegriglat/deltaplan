#!/usr/bin/env bash
# GPU-прогон тестов: Godot НЕ headless (маленькое окно, есть настоящий RenderingDevice),
# временный профиль пилота, тесты, помеченные TestCase.needs_gpu() == true, не пропускаются.
# tools/gpu_tests.sh [--filter=подстрока]
set -uo pipefail
cd "$(dirname "$0")/.."

profile="$(mktemp -d)"
# Godot с окном пересохраняет project.godot (шапка, порядок, значения по умолчанию) — вернуть как было.
pg_backup="$profile/project.godot.bak"
cp project.godot "$pg_backup"
trap 'cmp -s project.godot "$pg_backup" || cp "$pg_backup" project.godot; rm -rf "$profile"' EXIT

# Импорт: после правки .glsl без него тесты молча берут старый SPIR-V.
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
# --disable-vsync: при выключенном дисплее окно с vsync идёт ~1 кадр/с, и тесты по кадрам упираются в таймауты.
XDG_DATA_HOME="$profile" godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
	res://tests/run_tests.tscn -- --gpu "$@"
status=$?
exit $status
