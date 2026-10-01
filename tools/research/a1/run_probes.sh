#!/bin/sh
# Все пробы А1.1 подряд под замком GPU (минуты). Запуск: /home/greg/deltaplan/tools/job.sh start a1-probes 1800 sh run_probes.sh
cd "$(dirname "$0")"
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
for p in ${PROBES:-saddle prt ongudai}; do
  flock /tmp/heat_ca_gpu.lock $PY probe.py $p > out/$p.log 2>&1 || echo "$p failed"
done
