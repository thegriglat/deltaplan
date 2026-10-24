#!/bin/bash
# PR-6: before|after measurement, 8 threads, under the cpu lock. Run from the repo root:
#   bash tools/research/air_cascade/picard_rs/out/opt/PR-6/run.sh before|after
set -eu
W=${1:?before|after}
P=tools/research/air_cascade/picard_rs
BIN=$P/target/release/picard
D=$P/out/opt/PR-6
LOCK=".dpcli/dpcli lock cpu PR-6 --no-tmux --"
mkdir -p $D/$W
for c in u3_heat u3_mech u0_heat u6_heat; do
  $LOCK $BIN solve $HOME/data/air_cascade/ongudai/ongudai_d400_$c.json --threads 8 --out $D/$W/ongudai_d400_${c}_release_t8.json
done
$LOCK perf stat -e cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses -o $D/perf_${W}_u3_heat_t8.txt $BIN solve $HOME/data/air_cascade/ongudai/ongudai_d400_u3_heat.json --threads 8 --out /tmp/pr6_perf_$W.json
echo done > $D/$W.done
