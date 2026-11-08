#!/bin/bash
# Журнал нагрузки машины во время замеров SWG-3: время, loadavg, GPU util/память. sample_load.sh <out.log>
while true; do
  echo "$(date +%s) $(cut -d' ' -f1-3 /proc/loadavg) gpu $(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits | tr -d ' ')" >> "$1"
  sleep 10
done
