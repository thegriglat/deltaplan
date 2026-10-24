#!/bin/bash
# PR-4: профиль Rust-Пикара (u3_heat). Запуск из корня копии репозитория:
#   CARGO_PROFILE_RELEASE_DEBUG=line-tables-only cargo build --release --manifest-path tools/research/air_cascade/picard_rs/Cargo.toml
#   bash tools/research/air_cascade/picard_rs/out/prof/prof.sh
# Каждый запуск perf — под замком cpu (вес по маске picard_rs/target/release/picard solve).
set -u
P=tools/research/air_cascade/picard_rs
BIN=$P/target/release/picard
CASE=$HOME/data/air_cascade/ongudai/ongudai_d400_u3_heat.json
OUT=$P/out/prof
RAW=$HOME/data/air_cascade/picard_rs/prof
mkdir -p $OUT $RAW
LOCK=".dpcli/dpcli lock cpu PR-4 --no-tmux --"
# группы по <=4 события (PMU Haswell: 4 счётчика, без мультиплексирования) + общий набор (мультиплекс, как в карточке)
ALL=cycles,instructions,cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses,dTLB-load-misses,branches,branch-misses
GA=cycles,instructions,branches,branch-misses
GB=L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses
GC=dTLB-loads,dTLB-load-misses,cache-references,cache-misses
for t in ${THREADS:-18 8 1}; do
  run() { # имя события-набор файл-stat файл-R2
    $LOCK perf stat -e $1 -o $2 $BIN solve $CASE --threads $t --out $3 >/dev/null 2>&1
  }
  run $ALL $OUT/stat_u3_heat_t$t.txt $RAW/r2_all_t$t.json
  run $GA  $OUT/stat_u3_heat_t${t}_A.txt $RAW/r2_A_t$t.json
  run $GB  $OUT/stat_u3_heat_t${t}_B.txt $RAW/r2_B_t$t.json
  run $GC  $OUT/stat_u3_heat_t${t}_C.txt $RAW/r2_C_t$t.json
  # без perf — фазы базы под тем же бинарём
  $LOCK $BIN solve $CASE --threads $t --out $RAW/r2_noperf_t$t.json >/dev/null 2>&1
  # perf record: -F 499, без стека
  $LOCK perf record -F 499 -e cycles -o $RAW/perf_t$t.data $BIN solve $CASE --threads $t --out $RAW/r2_rec_t$t.json >/dev/null 2>$RAW/rec_t$t.err
  perf report -i $RAW/perf_t$t.data --stdio --no-children --sort symbol 2>/dev/null | head -150 > $OUT/report_u3_heat_t$t.txt
  perf report -i $RAW/perf_t$t.data --stdio --no-children --sort symbol,srcline 2>/dev/null | head -250 > $OUT/report_srcline_u3_heat_t$t.txt
done
echo done > $OUT/prof.done
# Дополнительно (запускалось отдельно, 8 потоков):
#  L1-промахи по функциям/строкам:
#   .dpcli/dpcli lock cpu PR-4 --no-tmux -- perf record -e L1-dcache-load-misses -c 100003 -o $RAW/perf_l1m_t8.data $BIN solve $CASE --threads 8 --out $RAW/r2_l1m_t8.json
#   perf report -i $RAW/perf_l1m_t8.data --stdio --no-children --sort symbol[,srcline] | head -80 > $OUT/report_l1miss[_srcline]_u3_heat_t8.txt
#  по направлениям и фазам: сборка harness/ (CARGO_TARGET_DIR=$RAW/harness_target cargo build --release --manifest-path $OUT/harness/Cargo.toml),
#   копия бинаря в $RAW/hbin/picard_rs/target/release/picard (путь под маску замка), затем bash $OUT/harness.sh; python3 $OUT/harness_table.py
#  сводка: python3 $OUT/build_summary.py && python3 $OUT/finish_summary.py ; perf annotate горячего solve_line: $RAW/annot_solve_line_t8.txt
#  Запуск 1 потока: stat полный; t1_A/t1_B (точные группы) оборваны по решению 17:21 (1/18 потоков не нужны), t1_C нет.
