#!/usr/bin/env bash
# весь счёт SY-10 одной очередью: места игры (game), затем места дельтаплана (holdout, затем train). Продолжение — той же командой.
# Запуск: tools/dp job --lock gpu start sy10-solve 200000 tools/research/air_synth/solver/run_hg.sh
cd "$(dirname "$0")"; PY=../../air_nn_pilot/.venv/bin/python; D=${AIR_SYNTH_DATA:-$HOME/air_synth_data}
export OMP_NUM_THREADS=1
P=out_solve_hg/progress.json
nice -n 10 $PY solve_corpus.py --relief-corpus $D/real/game_hg --conditions $D/conditions/game_hgw24 --plan hg --name game --k-cond 24 --workers 3 --progress $P &&
nice -n 10 $PY solve_corpus.py --relief-corpus $D/real/hg_v1 --conditions $D/conditions/hg_v1_hgw24 --plan hg --name hg_v1 --k-cond 24 --workers 3 --progress $P
