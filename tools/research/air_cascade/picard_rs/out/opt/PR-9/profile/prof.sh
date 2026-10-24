#!/bin/bash
# PR-9: profile of the current code (after PR-6/PR-7), u3_heat, 8 threads, as PR-4 (out/prof/prof.sh).
# Build with symbols first (codegen identical to release):
#   CARGO_PROFILE_RELEASE_DEBUG=line-tables-only cargo build --release --manifest-path tools/research/air_cascade/picard_rs/Cargo.toml
#   copy target/release/picard to $RAW/sym/picard_rs/target/release/picard  (path keeps the cpu lock mask)
# Run from the repository root: bash $D/profile/prof.sh [tag]   (tag: before|after)
set -u
P=tools/research/air_cascade/picard_rs
TAG=${1:-before}
RAW=$HOME/data/air_cascade/picard_rs/PR-9
BIN=$RAW/sym/picard_rs/target/release/picard
CASE=$HOME/data/air_cascade/ongudai/ongudai_d400_u3_heat.json
OUT=$P/out/opt/PR-9/profile
LOCK=".dpcli/dpcli lock cpu PR-9 --no-tmux --"
t=8
ALL=cycles,instructions,cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses,dTLB-load-misses,branches,branch-misses
GA=cycles,instructions,branches,branch-misses
GB=L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses
run() { $LOCK env LC_ALL=C perf stat -e $1 -o $2 $BIN solve $CASE --threads $t --out $RAW/r2_${TAG}_$3.json >/dev/null 2>&1; }
run $ALL $OUT/stat_${TAG}_t8.txt all
run $GA  $OUT/stat_${TAG}_t8_A.txt A
run $GB  $OUT/stat_${TAG}_t8_B.txt B
$LOCK env LC_ALL=C perf record -F 499 -e cycles -o $RAW/perf_${TAG}.data $BIN solve $CASE --threads $t --out $RAW/r2_rec_$TAG.json >/dev/null 2>$RAW/rec_$TAG.err
LC_ALL=C perf report -i $RAW/perf_${TAG}.data --stdio --no-children --sort symbol 2>/dev/null | head -80 > $OUT/report_${TAG}_t8.txt
LC_ALL=C perf report -i $RAW/perf_${TAG}.data --stdio --no-children --sort symbol,srcline 2>/dev/null | head -200 > $OUT/report_srcline_${TAG}_t8.txt
$LOCK env LC_ALL=C perf record -e L1-dcache-load-misses -c 100003 -o $RAW/perf_l1m_${TAG}.data $BIN solve $CASE --threads $t --out $RAW/r2_l1m_$TAG.json >/dev/null 2>&1
LC_ALL=C perf report -i $RAW/perf_l1m_${TAG}.data --stdio --no-children --sort symbol 2>/dev/null | head -60 > $OUT/report_l1miss_${TAG}_t8.txt
LC_ALL=C perf report -i $RAW/perf_l1m_${TAG}.data --stdio --no-children --sort symbol,srcline 2>/dev/null | head -120 > $OUT/report_l1miss_srcline_${TAG}_t8.txt
echo done > $OUT/prof_${TAG}.done
