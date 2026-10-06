#!/bin/bash
# AP-17: счёт сборки по фазам (основной вариант и без анабатики) → $AIR_SYNTH_DATA/phase/assembly_v1*, затем разбор.
set -e
PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
D=${AIR_SYNTH_DATA:-$HOME/air_synth_data}/phase
cd "$(dirname "$0")"
$PY run_assembly.py --out $D/assembly_v1 --workers 16
$PY run_assembly.py --out $D/assembly_v1_noana --workers 16 --cfg '{"slope_len_m": 0.0, "version": "assembly_v1_noana"}'
