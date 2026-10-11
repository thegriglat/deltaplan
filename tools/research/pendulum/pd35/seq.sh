#!/bin/bash
# PD-35: отклик, посадка, посадка с трима, штопор — по одному godot → <каталог>/s_*.txt
OUT=${1:?каталог вывода}; D=$(dirname "$0")
"$D/gt.sh" test_pendulum_flight_feel PD35_FEEL=1 > "$OUT/s_feel.txt" 2>&1
"$D/gt.sh" test_pendulum_landing_technique > "$OUT/s_lt.txt" 2>&1
"$D/gt.sh" test_pendulum_ground_landing PD35_ALL=1 > "$OUT/s_gl.txt" 2>&1
"$D/gt.sh" test_pendulum_spin > "$OUT/s_spin.txt" 2>&1
