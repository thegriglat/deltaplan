#!/bin/bash
# PR-9: счётчики perf по фазам и направлениям прогонки (harness/ — повтор одной фазы на разогретом поле).
# Разность двух длин серии (R2-R1 повторов) убирает подготовку и разогрев. Бинарь лежит по пути с маской замка cpu.
set -u
cd "$(git rev-parse --show-toplevel)"
export PROF_CASE=$HOME/data/air_cascade/ongudai/ongudai_d400_u3_heat.json
B=$HOME/data/air_cascade/picard_rs/PR-9/hbin/picard_rs/target/release/picard
OUT=tools/research/air_cascade/picard_rs/out/opt/PR-9/profile/harness_${TAG:-before}
T=${T:-8}; R1=${R1:-50}; R2=${R2:-450}
mkdir -p $OUT
for m in ${MODES:-dir0 dir1 dir2 bmom mom bheat heat proj kupd}; do
  for g in "cycles,L1-dcache-loads,L1-dcache-load-misses" "instructions,LLC-loads,LLC-load-misses" "dTLB-load-misses,cache-misses"; do
    gn=$(echo $g | cut -c1-3)
    for r in $R1 $R2; do
      .dpcli/dpcli lock cpu PR-9 --no-tmux -- perf stat -x, -e $g -o $OUT/${m}_${gn}_r$r.csv $B solve $m $r $T >> $OUT/${m}_time.txt 2>&1
    done
  done
done
echo done > $OUT/done
# Build: CARGO_TARGET_DIR=$HOME/data/air_cascade/picard_rs/PR-9/harness_target cargo build --release --manifest-path tools/research/air_cascade/picard_rs/out/opt/PR-9/profile/harness/Cargo.toml
# then copy the binary to $HOME/data/air_cascade/picard_rs/PR-9/hbin/picard_rs/target/release/picard (path keeps the cpu lock mask)
