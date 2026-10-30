#!/usr/bin/env bash
# Прогон xc_prof.gd: tools/profile/run.sh <имя> <аргументы xc_prof...>; результат build/rw15b/<имя>.json
set -euo pipefail
cd "$(dirname "$0")/../.."
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
name="$1"; shift
mkdir -p build/rw15b
godot --headless --path . res://tools/profile/xc_prof.tscn -- --synthetic --seed=1 --km=30 --out=build/rw15b/$name.json "$@" 2>&1 | tee build/rw15b/$name.log
