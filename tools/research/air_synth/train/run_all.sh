#!/bin/bash
# SY-11: полный конвейер S7 (после конца счёта SY-10). Запуск: tools/dp job --lock gpu start sy11-all 40000 tools/research/air_synth/train/run_all.sh
# Стадии идемпотентны: кеш — по готовым частям, обучение продолжается с last.pt, готовые результаты пропускаются.
set -euo pipefail
cd "$(dirname "$0")"
PY=../../air_nn_pilot/.venv/bin/python
NAME=${NAME:-hgw24_p2}
ROOT=${AIR_SYNTH_DATA:-$HOME/air_synth_data}
RUN=$ROOT/train/$NAME
GAME=$RUN/cache/game__hgw24__s0-939a467
HG=$RUN/cache/hg_v1__hgw24__s0-939a467
export OMP_NUM_THREADS=4
$PY s7_cache.py --name "$NAME" --workers 8
# (1) обучение на train с ранней остановкой по проверке (10 % мест)
[ -f "$RUN/val/result_val.json" ] || $PY s7_train.py --mode val --cache "$HG" --run "$RUN/val"
# оценка: holdout + места игры (CPU)
$PY s7_eval.py --weights "$RUN/val/best.pt" --train-cache "$HG" --holdout-cache "$HG" --game-cache "$GAME" --out out
# (2) финальное: все места, то же число шагов по тому же расписанию
read -r STOP SCHED < <($PY -c "
import json; r=json.load(open('$RUN/val/result_val.json')); b=r['best']
print(b['gstep'], r['hp']['max_epochs']*r['spe'])")
[ -f "$RUN/final/result_final.json" ] || $PY s7_train.py --mode final --cache "$HG" "$GAME" --run "$RUN/final" --stop-steps "$STOP" --schedule-steps "$SCHED"
$PY s7_export.py --weights "$RUN/final/final.pt" --cache "$HG" --out out
