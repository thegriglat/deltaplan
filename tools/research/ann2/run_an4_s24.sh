#!/bin/bash
# AN-4: два контрольных прогона на 24000 шагов (косинус внутри 24000 — лучшая точка ≈ конец): разложенная голова и прежняя MLP-голова,
# остальное как an4 (N случая, механические случаи). Параллельно под одним замком GPU.
cd "$(dirname "$0")"
PY=/home/greg/deltaplan-ann2-AN-4/tools/research/air_nn_pilot/.venv/bin/python
C="--steps 24000 --batch 32 --lr 2e-3 --ema 0.999 --amp 1 --val_every 1000 --save_every 4000 --fresh --seed 1"
$PY train.py --run an4_d24 $C > /tmp/an4_d24.log 2>&1 &
$PY train.py --run an4_m24 $C --head mlp > /tmp/an4_m24.log 2>&1 &
wait
