#!/usr/bin/env bash
# run_starts.sh <sha>: полный импорт ресурсов (если нужен) и зонд стартов aushtau_south / kayancha_south
set -uo pipefail
sha=$1
d=$(cd "$(dirname "$0")" && pwd)
wt=$HOME/worktrees/deltaplan/picard-terrain-PT-14-$sha
export XDG_DATA_HOME=$HOME/.cache/dp-xdg/picard-terrain-PT-14-$sha
cd "$wt" && godot --headless --path . --import >/dev/null 2>&1
$d/run_godot.sh $sha ${2:-probe_starts} "--file=res://tests/atmosphere/probe_starts.gd"
