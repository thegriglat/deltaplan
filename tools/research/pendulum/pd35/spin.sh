#!/bin/bash
# PD-35: спин и выход из срыва по вариантам (какая правка) → $1
OUT=$1; : > "$OUT"; D=$(dirname "$0")
run() { local name=$1; shift; "$D/gt.sh" "test_pendulum_spin" "$@" 2>&1 | grep -E '^\s+(training|sport|laminar):|FAIL|тестов' | sed "s/^/$name | /" >> "$OUT"; }
run all
run ax1 PD35_ALPHAEXACT=1
run cp0 PD35_CPREV=0
run cd0 PD35_SWEEPNORM=0
run pre PD35_CPREV=0 PD35_SWEEPNORM=0
