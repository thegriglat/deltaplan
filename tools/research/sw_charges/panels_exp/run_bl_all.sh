#!/usr/bin/env bash
# SWC-17: все случаи с пограничным слоем (3 процесса). Из корня копии: .dpcli/dpcli lock cpu swc17 -- bash tools/research/sw_charges/panels_exp/run_bl_all.sh
set -u
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
PY=tools/research/cascade_2d/py
R=tools/research/sw_charges/panels_exp/run_bl.py
{ printf '%s\n' PERD_NE C4 C2 PERD_SW C1 LW_H3 LW_MD LW_UCD LW_H5 LW_GI LW_H8
  echo "LW_H3 50"; echo "LW_UCD 50"; echo "LW_H3 150"; echo "LW_UCD 150"; } | xargs -P 3 -I{} bash -c "$PY -I $R {}"
# чувствительность Perdigão к z0 слоя (0,1 м вместо z0_nominal): отдельный запуск
# printf '%s\n' "PERD_NE 0.1" "PERD_SW 0.1" | xargs -P 2 -I{} bash -c "$PY -I $R {}"
