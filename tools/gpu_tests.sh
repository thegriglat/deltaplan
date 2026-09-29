#!/usr/bin/env bash
# GPU-прогон тестов: Godot НЕ headless (маленькое окно, есть настоящий RenderingDevice),
# временный профиль пилота, тесты, помеченные TestCase.needs_gpu() == true, не пропускаются.
# tools/gpu_tests.sh [--filter=подстрока]
set -uo pipefail
cd "$(dirname "$0")/.."

profile="$(mktemp -d)"
trap 'rm -rf "$profile"' EXIT

XDG_DATA_HOME="$profile" godot --path . --audio-driver Dummy --resolution 320x240 \
	res://tests/run_tests.tscn -- --gpu "$@"
exit $?
