#!/bin/bash
# SY-11: полный конвейер S7 (после конца счёта SY-10). Запуск: tools/dp job --lock gpu start sy11-all 40000 tools/research/air_synth/train/run_all.sh
# Стадии идемпотентны: кеш — по готовым частям, обучение продолжается с last.pt, готовые результаты пропускаются.
set -euo pipefail
cd "$(dirname "$0")"
PY=../../air_nn_pilot/.venv/bin/python
NAME=${NAME:-hgw24_p2}
ROOT=${AIR_SYNTH_DATA:-$HOME/air_synth_data}
RUN=$ROOT/train/$NAME
GAME=$RUN/cache/game2__hgw24__s0-939a467
HG=$RUN/cache/hg_v2__hgw24__s0-939a467
export OMP_NUM_THREADS=4
$PY s7_cache.py --name "$NAME" --workers 8
# (1) обучение на train с ранней остановкой по проверке (10 % мест)
[ -f "$RUN/val/result_val.json" ] || $PY s7_train.py --mode val --cache "$HG" --run "$RUN/val"
# оценка: holdout + места игры (CPU)
$PY s7_eval.py --weights "$RUN/val/best.pt" --train-cache "$HG" --holdout-cache "$HG" --game-cache "$GAME" --out out
# решение пользователя 05.10: только первое обучение; финальное переобучение (s7_train.py --mode final) — позже, на пересчитанном наборе.
# ONNX — первой сети (best.pt, EMA лучшей эпохи)
$PY s7_export.py --weights "$RUN/val/best.pt" --cache "$HG" --out out
