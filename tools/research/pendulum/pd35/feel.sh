#!/bin/bash
# PD-35: отклик в полёте до (физика 1.5.5) и после → <каталог>/feel_pre.txt, feel_post.txt; таблица — feel_table.py
OUT=${1:?каталог вывода}; D=$(dirname "$0")
"$D/gt.sh" test_pendulum_flight_feel PD35_FEEL=1 PD35_SWEEPNORM=0 PD35_CPREV=0 > "$OUT/feel_pre.txt" 2>&1 &
"$D/gt.sh" test_pendulum_flight_feel PD35_FEEL=1 > "$OUT/feel_post.txt" 2>&1 &
wait
