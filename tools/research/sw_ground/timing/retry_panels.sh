#!/bin/bash
# Дозапуск повторений, упавших по нехватке памяти GPU (чужие задачи держат до 10 из 12 ГБ): ждёт ≥ 8 ГБ свободных.
HERE="$(cd "$(dirname "$0")" && pwd)"; RAW="${1:?raw_dir}"
for i in $(seq 1 360); do
  used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
  if [ "$used" -lt 4200 ]; then "$HERE/run_panels.sh" "$RAW" 3; break; fi
  sleep 10
done
echo done
