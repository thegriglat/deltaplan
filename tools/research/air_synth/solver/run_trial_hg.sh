#!/usr/bin/env bash
# пробный счёт SY-10: 24 случая hgw24 (корзины утро/день/вечер × слабый/сильный ветер) по местам дельтаплана, 3 воркера -> <solve>__trial
cd "$(dirname "$0")"; PY=../../air_nn_pilot/.venv/bin/python; D=${AIR_SYNTH_DATA:-$HOME/air_synth_data}
export OMP_NUM_THREADS=1
nice -n 10 $PY solve_corpus.py --relief-corpus $D/real/hg_v1 --conditions $D/conditions/hg_v1_hgw24 --plan hg --name hg_v1 --k-cond 24 --workers 3 --trial 24 --progress out_solve_hg/trial_progress.json
