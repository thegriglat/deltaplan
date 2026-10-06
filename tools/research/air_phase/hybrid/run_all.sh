#!/bin/bash
# AP-18 (P9): «фазы + Пикар» по SY-12. Стадии: prep (CPU) → gpu (под dp job --lock gpu) → final (CPU) → разбор → clean.
#   bash run_all.sh prep | gpu | final | analysis | clean
# gpu: сначала тесты P4 v6 (test_batch_solver -k v6); холодный Пикар считается в любом случае, гибрид и варианты — если тесты прошли.
set -e
PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
OUT=${AIR_SYNTH_DATA:-$HOME/air_synth_data}/phase/hybrid_v1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
cd "$ROOT"
case "$1" in
  prep)     $PY $HERE/run_hybrid.py prep --out $OUT --workers 14 ;;
  gpu)
    mkdir -p $OUT
    if $PY -m pytest -q tools/research/air_phase/tests/test_batch_solver.py -k v6 > $OUT/test_v6.log 2>&1; then T=ok; else T=fail; fi
    echo "test_v6: $T" | tee -a $OUT/test_v6.log
    $PY $HERE/run_hybrid.py gpu --out $OUT --variants cold
    if [ "$T" = ok ]; then $PY $HERE/run_hybrid.py gpu --out $OUT --variants hybrid,fallback,cold_omap,timing; fi ;;
  final)    $PY $HERE/run_hybrid.py final --out $OUT --workers 14 ;;
  analysis) $PY tools/research/air_phase/analysis/AP-18/run.py --data $OUT ;;
  clean)    $PY $HERE/run_hybrid.py clean --out $OUT ;;
  *) echo "стадия: prep | gpu | final | analysis | clean"; exit 2 ;;
esac
