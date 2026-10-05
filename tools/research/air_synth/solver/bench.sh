#!/usr/bin/env bash
# кривая воркеров (те же 12 случаев) + расширенная выборка 48 случаев (12 условий на рельеф), под одним замком GPU
set -e
PY=../../air_nn_pilot/.venv/bin/python
export OMP_NUM_THREADS=1
$PY h7_run.py --workers 1 --out out_h7/bench_w1
$PY h7_run.py --workers 3 --out out_h7/bench_w3
$PY h7_run.py --workers 4 --out out_h7/bench_w4
$PY h7_run.py --workers 2 --n-cond 12 --out out_h7/ext12
