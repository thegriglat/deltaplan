#!/bin/bash
# PR-6: per-direction L1 counters (harness of PR-4 built unmodified against the current lines.rs; binary
# copied to a path matching the cpu lock mask). Usage from repo root: bash <this> after
set -u
W=${1:-after}
P=tools/research/air_cascade/picard_rs
export PROF_CASE=$HOME/data/air_cascade/ongudai/ongudai_d400_u3_heat.json
B=$HOME/data/air_cascade/picard_rs/pr6/hbin/picard_rs/target/release/picard
OUT=$P/out/opt/PR-6/harness_$W
mkdir -p $OUT
for m in dir0 dir1 dir2; do
  for r in 50 450; do
    .dpcli/dpcli lock cpu PR-6 --no-tmux -- perf stat -x, -e cycles,L1-dcache-loads,L1-dcache-load-misses -o $OUT/${m}_cyc_r$r.csv $B solve $m $r 8 >> $OUT/${m}_time.txt 2>&1
  done
done
echo done > $OUT/done
