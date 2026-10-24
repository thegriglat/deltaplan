#!/bin/bash
# Usage: run.sh before|after  (run from repo root; 8 threads, under the cpu lock)
set -e
W=$1; D=tools/research/air_cascade/picard_rs/out/opt/PR-7
B=tools/research/air_cascade/picard_rs/target/release/picard
for c in u3_heat u3_mech u0_heat u6_heat; do
  .dpcli/dpcli lock cpu PR-7 --no-tmux -- $B solve ~/data/air_cascade/ongudai/ongudai_d400_$c.json --threads 8 --out $D/$W/ongudai_d400_${c}_release_t8.json
done
.dpcli/dpcli lock cpu PR-7 --no-tmux -- perf stat -e cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses -o $D/perf_${W}_u3_heat_t8.txt $B solve ~/data/air_cascade/ongudai/ongudai_d400_u3_heat.json --threads 8 --out /tmp/pr7_$W.json
