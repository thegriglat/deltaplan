#!/bin/bash
# SWG-3: панели на окнах игры, повторения в свежих процессах. run_panels.sh <raw_dir> [reps=3]
# (панели 100 м rep 0 и rotor 100 м rep 0 уже сняты первым запуском — файлы существуют, пропускаются)
HERE="$(cd "$(dirname "$0")" && pwd)"; RAW="${1:?raw_dir}"; REPS="${2:-3}"
mkdir -p "$RAW"
for rep in $(seq 0 $((REPS-1))); do
  for m in panels panels_rotor; do
    for dx in 100 50; do
      f="$RAW/${m}_${dx}_${rep}.json"
      [ -f "$f" ] && continue
      "$HERE/../py" "$HERE/panels_timing.py" $dx $m $rep "$f" >> "$RAW/panels_${m}_${dx}_${rep}.log" 2>&1
    done
  done
done
echo done
