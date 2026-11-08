#!/usr/bin/env bash
# SWC-19: все случаи с внутренним слоем Jackson–Hunt (3 процесса). Из корня копии: .dpcli/dpcli lock cpu swc19 -- bash tools/research/sw_charges/panels_exp/run_jh_all.sh
set -u
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
PY=${PY:-tools/research/cascade_2d/py}   # нужен scipy (Perdigão); библиотека panels2d — только NumPy
R=tools/research/sw_charges/panels_exp/run_jh.py
printf '%s\n' PERD_NE C4 C2 PERD_SW C1 LW_H3 LW_MD LW_UCD LW_H5 LW_GI LW_H8 | xargs -P 3 -I{} bash -c "$PY -I $R {}"
