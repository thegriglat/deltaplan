#!/usr/bin/env bash
# SWC-16: все пересчёты (3 процесса). Из корня копии: .dpcli/dpcli lock cpu swc16 -- bash tools/research/sw_charges/panels_exp/run_cc_all.sh
set -u
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
PY=${CASCADE2D_VENV:-$HOME/.cache/cascade_2d/venv}/bin/python
R=tools/research/sw_charges/panels_exp/run_cc.py
printf '%s\n' C4 C2 C1 LW_H3 LW_MD LW_UCD LW_H5 LW_GI LW_H8 | xargs -P 3 -I{} bash -c "$PY -I $R {}"
