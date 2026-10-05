#!/usr/bin/env bash
# пробный счёт: по 12 случаев равномерно по плану (реальные и модельные; со штилём)
cd "$(dirname "$0")"; PY=../../air_nn_pilot/.venv/bin/python; D=${AIR_SYNTH_DATA:-$HOME/air_synth_data}
export OMP_NUM_THREADS=1
nice -n 10 $PY solve_corpus.py --relief-corpus $D/real/p6v3 --conditions $D/conditions/p6v3_p2c12 --plan real --trial 12 --workers 3 &&
nice -n 10 $PY solve_corpus.py --relief-corpus $D/corpus/fs1_10k --conditions $D/conditions/fs1_360_p2c12 --plan model --trial 12 --workers 3
