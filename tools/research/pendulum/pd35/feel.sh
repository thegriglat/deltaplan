#!/bin/bash
# PD-35: отклик в полёте до/после → $1 (pre) и $2 (pd35); плюс посадка (все проверки теста) → $3
D=$(dirname "$0")
"$D/gt.sh" test_pendulum_flight_feel PD35_FEEL=1 PD35_SWEEPNORM=0 PD35_CPREV=0 PD35_ALPHAEXACT=0 > "$1" 2>&1 &
"$D/gt.sh" test_pendulum_flight_feel PD35_FEEL=1 > "$2" 2>&1 &
wait
"$D/gt.sh" test_pendulum_landing_technique > "$3" 2>&1
