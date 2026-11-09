#!/bin/bash
# SWG-6: прогон вариантов в свежих процессах; при нехватке памяти GPU (чужие задачи) ждёт (свободно ≥ ~3,3 ГБ) и повторяет (до 40 попыток × 30 с).
# run_query.sh <raw_dir> <список "dx:variant:rep" ...>. Уже снятые (файл есть) пропускает.
HERE="$(cd "$(dirname "$0")" && pwd)"; RAW="${1:?raw_dir}"; shift
mkdir -p "$RAW"
for spec in "$@"; do
  IFS=: read dx var rep <<< "$spec"
  f="$RAW/q_${dx}_${var}_${rep}.json"
  [ -f "$f" ] && continue
  for try in $(seq 1 40); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
    if [ "$used" -lt 9000 ]; then
      "$HERE/../py" "$HERE/query_timing.py" $dx $var $rep "$f" --raw "$RAW" >> "$RAW/q_${dx}_${var}_${rep}.log" 2>&1
      [ -f "$f" ] && break
    fi
    sleep 30
  done
done
echo done
