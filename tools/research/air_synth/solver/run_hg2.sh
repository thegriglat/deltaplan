#!/usr/bin/env bash
# весь счёт SY-12 одной очередью по hg_v2 (S1 v5): места игры (game2), затем места дельтаплана (holdout, затем train). Продолжение — той же командой.
# Запуск (ТОЛЬКО по команде координатора, после первого обучения SY-11): tools/dp job --lock gpu start sy12-solve 200000 tools/research/air_synth/solver/run_hg2.sh
cd "$(dirname "$0")"; PY=../../air_nn_pilot/.venv/bin/python; D=${AIR_SYNTH_DATA:-$HOME/air_synth_data}
export OMP_NUM_THREADS=1
P=out_solve_hg2/progress.json
nice -n 10 $PY solve_corpus.py --relief-corpus $D/real/game_hg2 --conditions $D/conditions/game2_hgw24 --plan hg --name game2 --k-cond 24 --workers 3 --progress $P &&
nice -n 10 $PY solve_corpus.py --relief-corpus $D/real/hg_v2 --conditions $D/conditions/hg_v2_hgw24 --plan hg --name hg_v2 --k-cond 24 --workers 3 --progress $P
