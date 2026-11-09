#!/usr/bin/env bash
# run_godot.sh <sha> <имя_лога_без_расширения> <фильтр|--file=res://...> [доп. аргументы после --]
# Запускает тесты Godot в копии picard-terrain-PT-14-<sha>; лог — out/PT-14/logs/<sha>-<имя>.log
set -uo pipefail
sha=$1; name=$2; flt=$3; shift 3
wt=$HOME/worktrees/deltaplan/picard-terrain-PT-14-$sha
out=$HOME/worktrees/deltaplan/picard-terrain-PT-14/tools/research/picard_terrain/out/PT-14/logs
mkdir -p "$out"
export PT14_OUT=$HOME/worktrees/deltaplan/picard-terrain-PT-14/tools/research/picard_terrain/out/PT-14
export XDG_DATA_HOME=$HOME/.cache/dp-xdg/picard-terrain-PT-14-$sha
cd "$wt"
for f in probe_ridge probe_snap probe_starts; do cp "$HOME/worktrees/deltaplan/picard-terrain-PT-14/tools/research/picard_terrain/PT-14/$f.gd" tests/atmosphere/$f.gd; done
[ -d .godot ] || godot --headless --path . --import >/dev/null 2>&1
if [[ $flt == --file=* ]]; then a="$flt"; else a="--filter=$flt"; fi
godot --headless --path . res://tests/run_tests.tscn -- "$a" "$@" > "$out/$sha-$name.log" 2>&1
echo "exit=$?" >> "$out/$sha-$name.log"
