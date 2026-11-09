#!/bin/bash
# SWG-3: Пикар крейта (Formula) на окнах 100/50 м, Онгудай, 7,5 м/с с 151° → 9 м/с с 181°.
# Запуск (сам замок CPU берёт каждый прогон; `cargo run --release` по cpu_weights — 8 слотов = 8 ядер квоты):
#   .dpcli/dpcli job start swg3-picard 20000 tools/research/sw_ground/timing/run_picard.sh <raw_dir>
# Сборка бинарника — там же: CARGO_TARGET_DIR=tools/research/sw_ground/timing/target (свой каталог, rust/ не трогаем).
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../../.." && pwd)"; RAW="${1:?raw_dir}"
mkdir -p "$RAW"
export CARGO_TARGET_DIR="$HERE/target"
for spec in "8 5 3" "8 1 2" "2 5 3" "2 1 1"; do
  set -- $spec
  for rep in $(seq 0 $(($3-1))); do
    f="$RAW/picard_$1_$2_$rep.json"; [ -f "$f" ] && continue
    "$ROOT/.dpcli/dpcli" lock cpu "swg3-p$1-$2-$rep" -- cargo run --release -q --manifest-path "$HERE/rs/Cargo.toml" -- "$ROOT" "$f" $1 $2 7.5 151 >> "$RAW/picard_$1_$2_$rep.log" 2>&1
  done
done
echo done
