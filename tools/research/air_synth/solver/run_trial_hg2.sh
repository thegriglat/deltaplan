#!/usr/bin/env bash
# пробный счёт SY-12: 20 случаев hgw24 (корзины час × ветер) по hg_v2, 3 воркера -> <solve>__trial; progress — out_solve_hg2/progress.json (его перезапишет полный счёт)
cd "$(dirname "$0")"; PY=../../air_nn_pilot/.venv/bin/python; D=${AIR_SYNTH_DATA:-$HOME/air_synth_data}
export OMP_NUM_THREADS=1
nice -n 10 $PY solve_corpus.py --relief-corpus $D/real/hg_v2 --conditions $D/conditions/hg_v2_hgw24 --plan hg --name hg_v2 --k-cond 24 --workers 3 --trial 20 --progress out_solve_hg2/progress.json
