#!/usr/bin/env bash
# RW-21a: tools/build.sh all --release с профилем Godot своей копии.
# Необязательный PATH_PREFIX_SHIM=<каталог> с обёрткой godot — обход зависания air_model_hash.gd.
set -uo pipefail
cd "$(dirname "$0")/../.."
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}"
mkdir -p "$XDG_DATA_HOME"
[[ -n "${PATH_PREFIX_SHIM:-}" ]] && export PATH="$PATH_PREFIX_SHIM:$PATH"
time tools/build.sh all --release
echo "BUILD_RC=$?"
