#!/usr/bin/env bash
# SWC-12: все случаи (3 параллельных процесса, 1 поток BLAS каждый) + чувствительность. Запуск из корня копии:
#   .dpcli/dpcli lock cpu swc12 -- bash tools/research/sw_charges/panels_exp/run_all.sh
set -u
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
PY=${CASCADE2D_VENV:-$HOME/.cache/cascade_2d/venv}/bin/python
R=tools/research/sw_charges/panels_exp/run_case.py
{
echo "C4"; echo "PERD_NE"; echo "PERD_SW"; echo "C2"; echo "C1"
for m in H3 MD UCD H5 GI H8; do echo "LW_$m"; done
echo "C2 --ds 12.5 --tag _ds12.5"; echo "C2 --ds 50 --tag _ds50"
echo "PERD_NE --smooth 25 --tag _sm25"; echo "PERD_NE --smooth 60 --tag _sm60"
echo "C1 --ds 12.5 --tag _ds12.5"; echo "LW_H3 --ds 12.5 --tag _ds12.5"
} | xargs -P 3 -I{} bash -c "$PY -I $R {}" 
