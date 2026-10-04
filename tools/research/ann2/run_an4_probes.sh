#!/bin/bash
# AN-4: короткие пробы по одной правке (6000 шагов, косинус внутри 6000, батч 32, lr 2e-3): что из трёх правок что даёт.
# Сравнение — по потере проверки (одни и те же механические случаи проверки у всех проб), разброс — по двум зёрнам.
cd "$(dirname "$0")"
PY=/home/greg/deltaplan-ann2-AN-4/tools/research/air_nn_pilot/.venv/bin/python
C="--steps 6000 --batch 32 --lr 2e-3 --ema 0.999 --amp 1 --val_every 1000 --save_every 3000 --fresh"
$PY train.py --run an4p_base  $C --seed 1
$PY train.py --run an4p_seed2 $C --seed 2
$PY train.py --run an4p_oldN  $C --seed 1 --fr_old 1
$PY train.py --run an4p_mlp   $C --seed 1 --head mlp
$PY train.py --run an4p_all   $C --seed 1 --regime all
