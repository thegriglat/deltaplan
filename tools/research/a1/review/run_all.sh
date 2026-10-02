#!/bin/sh
# А1.3 (ревью): пробы приёмки (1)–(3) + Онгудай, Askervein (4), диагноз 200 м — подряд, GPU под замком.
# Запуск: /home/greg/deltaplan/tools/dp job start a1rev 3600 sh run_all.sh   (из этого каталога)
cd "$(dirname "$0")"
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
L="flock /tmp/heat_ca_gpu.lock"
$L $PY run_probes.py prt saddle const ongudai > out/probes.log 2>&1 || echo "probes failed"
# (4) Askervein check25: run_grid.py пропускает уже посчитанные точки — опорный файл отложить и вернуть
( cd ../../recal && mv out/runs_check25.jsonl out/runs_check25.keep && \
  $PY run_grid.py check25 > ../a1/review/out/askervein.log 2>&1; \
  mv out/runs_check25.jsonl ../a1/review/out/runs_check25_review.jsonl; mv out/runs_check25.keep out/runs_check25.jsonl )
$PY ../askervein_chi2.py out/runs_check25_review.jsonl > out/askervein_chi2.json 2>&1
$PY ../askervein_chi2.py ../../recal/out/runs_check25_a1.jsonl > out/askervein_chi2_a1.json 2>&1
for v in ${DIAG:-base32 base64}; do
  $L $PY diag200.py $v ${DIAG_ITERS:-400} > out/diag200_$v.log 2>&1 || echo "diag $v failed"
done
echo done
