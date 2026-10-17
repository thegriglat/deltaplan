#!/bin/bash
# AWW-1: прогон варианта с патчем: run_proto.sh <метка> <patch> [старт…] — применить патч, прогнать run.sh (calc), откатить.
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../../.." && pwd)"; cd "$ROOT" || exit 2
TAG=${1:?метка}; P=${2:?patch}; shift 2
git apply "$P" || exit 3
ARGS=("$@"); [ ${#ARGS[@]} -eq 0 ] && ARGS=(training_island/ridge_west:calc training_island/thermal_plain:calc training_island/landing_hill:calc training_island/lee_bowl:calc volcano_island/east_cliffs:calc volcano_island/crater_ridge:calc volcano_island/thermal_slope:calc volcano_island/plateau_landing:calc)
"$HERE/run.sh" "$TAG" "${ARGS[@]}"
git checkout -- scripts configs project.godot
git status --short -- scripts configs
