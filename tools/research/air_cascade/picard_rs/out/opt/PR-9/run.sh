#!/bin/bash
# Usage: [BIN=<picard binary; its path must contain picard_rs/target/release/picard>] run.sh before|after  (from the repo root; 8 threads, under the cpu lock, release binary built without symbols)
# "before" = the binary built from the parent commit (HEAD of feature/picard-rs), measured in the same series as "after"
set -e
W=$1; D=tools/research/air_cascade/picard_rs/out/opt/PR-9
B=${BIN:-tools/research/air_cascade/picard_rs/target/release/picard}
for c in u3_heat u3_mech u0_heat u6_heat; do
  .dpcli/dpcli lock cpu PR-9 --no-tmux -- $B solve ~/data/air_cascade/ongudai/ongudai_d400_$c.json --threads 8 --out $D/$W/ongudai_d400_${c}_release_t8.json
done
.dpcli/dpcli lock cpu PR-9 --no-tmux -- env LC_ALL=C perf stat -e cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses -o $D/perf_${W}_u3_heat_t8.txt $B solve ~/data/air_cascade/ongudai/ongudai_d400_u3_heat.json --threads 8 --out /tmp/pr9_$W.json
