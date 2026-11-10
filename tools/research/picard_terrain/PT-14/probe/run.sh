#!/usr/bin/env bash
# run.sh <sha>: прогон зонда крейта на гребне 25 и 21,6 км/ч (6 м/с), без ветра и на плоском месте
set -uo pipefail
sha=$1
wt=$HOME/worktrees/deltaplan/picard-terrain-PT-14-$sha
bin=$HOME/.cache/dp-target/PT-14-probe-$sha/release/pt14-probe
out=$HOME/worktrees/deltaplan/picard-terrain-PT-14/tools/research/picard_terrain/out/PT-14/probe
mkdir -p "$out"
$bin "$wt" ridge 25.0 "$out/$sha-ridge25.json"
$bin "$wt" ridge 21.6 "$out/$sha-ridge6.json"
$bin "$wt" flat 14.0 "$out/$sha-flat14.json" 9600
# ровно входы фасада GDScript (файл пишет probe_ridge.gd)
G=$HOME/worktrees/deltaplan/picard-terrain-PT-14/tools/research/picard_terrain/out/PT-14/gdinput-250.json
[ -f "$G" ] && PT14_GDINPUT=$G $bin "$wt" ridge 25.0 "$out/$sha-ridge25gd.json"
