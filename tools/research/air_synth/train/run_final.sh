#!/bin/bash
# SY-11 (б): финальное обучение на всех местах (train + holdout + игры), эпох = лучшая по holdout эпоха первого обучения (по умолчанию 130), ONNX из снимка этой эпохи.
set -euo pipefail
cd "$(dirname "$0")"
PY=../../air_nn_pilot/.venv/bin/python
NAME=${NAME:-hgw24_p2}; EP=${EP:-130}
RUN=${AIR_SYNTH_DATA:-$HOME/air_synth_data}/train/$NAME
HG=$RUN/cache/hg_v2__hgw24__s0-939a467; GAME=$RUN/cache/game2__hgw24__s0-939a467
export OMP_NUM_THREADS=4
[ -f "$RUN/final/result_final.json" ] || $PY s7_train.py --mode final --cache "$HG" "$GAME" --run "$RUN/final" --max-epochs "$EP" --schedule-epochs 150
$PY s7_export.py --weights "$RUN/final/ckpt/ep$(printf %03d "$EP").pt" --cache "$GAME" --out out
