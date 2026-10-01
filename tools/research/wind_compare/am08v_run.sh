#!/usr/bin/env bash
# AM-08в: повторная выгрузка air (6 вариантов Онгудая) в out/am08v/; готовые пропускает.
# Сильный ветер ещё раз — с болтанкой (40 выборок в точке, пики рывков) и диагностикой (r, dx,
# lee_f, U_H): *_turb_air. ./am08v_run.sh <копия>   (main не пересчитывается — аналитика та же)
set -uo pipefail
copy="${1:-/home/greg/deltaplan-wf-am08v}"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$here/out/am08v"
S="--cx=-1300 --cn=0 --half=1000 --step=100"
M="--half=5000 --step=400 --gstep=200 --levels=50,100,200,400,800,1200"
T="--wind=9 --turb=40 --diag=1"
while read -r name args; do
  [ -s "$here/out/am08v/$name.json" ] && { echo "есть: $name"; continue; }
  echo "== $name $args"
  "$here/run.sh" "$copy" "am08v/$name" $args 2>&1 | grep -E "dump_wind|ERROR" | cut -c1-300
done <<LIST
air
strong_air --wind=9
saddle_air $S
saddle_strong_air $S --wind=9
mountain_air $M
mountain_strong_air $M --wind=9
strong_turb_air $T
saddle_strong_turb_air $S $T
mountain_strong_turb_air $M $T
LIST
