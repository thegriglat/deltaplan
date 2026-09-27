#!/usr/bin/env bash
# Проверка стиля GDScript (официальный style guide Godot) — gdtoolkit через uvx.
# tools/lint.sh [пути...]   — по умолчанию весь код; tools/lint.sh --format — ещё и проверка форматирования.
set -euo pipefail
cd "$(dirname "$0")/.."
fmt=0
if [[ "${1:-}" == "--format" ]]; then fmt=1; shift; fi
paths=("${@:-scripts scenes tests}")
# shellcheck disable=SC2068
uvx --from "gdtoolkit==4.*" gdlint ${paths[@]}
if [[ $fmt == 1 ]]; then
	# shellcheck disable=SC2068
	uvx --from "gdtoolkit==4.*" gdformat --check ${paths[@]}
fi
