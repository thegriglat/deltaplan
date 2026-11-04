#!/usr/bin/env bash
# CSD-4: все прогоны каскада. Запуск под замком cpu:
#   .dpcli/dpcli lock cpu csd4-run -- tools/research/cascade_2d/experiments/run_cascade.sh
# Случаи C0..C4 x старт 400/200 x V0,V1,V2,V3,V3h (сид 1) -> $DATA/fields/<C> и out/runs/<C>;
# V3h сиды 2,3 -> $DATA/fields_seeds/s<k>/<C>; 8 потоков (V3) -> $DATA/fields_t8/<C> (побитное сравнение);
# опрос точки (5000 точек) для V0..V3h от 400; повторы времени V3 -> out/timing/*.txt.
set -euo pipefail
R="$(cd "$(dirname "$0")/../../../.." && pwd)"
B="$R/tools/research/cascade_2d/cascade_rs/target/release/cascade"
DATA="${CASCADE2D_DATA:-$HOME/data/cascade_2d}"
OUT="$R/tools/research/cascade_2d/out"
SCR="${CSD4_SCRATCH:-/tmp/csd4_scratch}"; mkdir -p "$OUT/timing" "$SCR"
for C in C0 C1 C2 C3 C4; do
  F="$DATA/fields/$C"; mkdir -p "$F"
  for P in 400 200; do
    PF="$F/picard_none_d$P.json"; [ $P = 200 ] && PF="$DATA/fields_p200t/$C/picard_none_d200.json"  # trim_p200.py
    for V in V0 V1 V2 V3 V3h; do
      "$B" descend --parent "$PF" --case $C --variant $V --seed 1 --threads 1 --out-dir "$F"
    done
  done
  for V in V0 V1 V2 V3 V3h; do
    "$B" query --parent "$F/picard_none_d400.json" --case $C --variant $V --seed 1 --points 5000 --out-dir "$F" --runs-dir "$OUT/runs"
  done
  for S in 2 3; do
    mkdir -p "$DATA/fields_seeds/s$S/$C"
    "$B" descend --parent "$F/picard_none_d400.json" --case $C --variant V3h --seed $S --threads 1 \
       --out-dir "$DATA/fields_seeds/s$S/$C" --runs-dir "$SCR/runs_s$S"
  done
  mkdir -p "$DATA/fields_t8/$C"
  for V in V0 V1 V2 V3 V3h; do
    "$B" descend --parent "$F/picard_none_d400.json" --case $C --variant $V --seed 1 --threads 8 \
       --out-dir "$DATA/fields_t8/$C" --runs-dir "$SCR/runs_t8"
  done
  : > "$OUT/timing/${C}_V3_from400.txt"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    "$B" descend --parent "$F/picard_none_d400.json" --case $C --variant V3 --threads 1 \
       --out-dir "$SCR/t_$C" --runs-dir "$SCR/runs_t" >> "$OUT/timing/${C}_V3_from400.txt"
  done
done
