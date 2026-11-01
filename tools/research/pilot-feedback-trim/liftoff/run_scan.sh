#!/bin/bash
# Сетка PFT-4: alpha_neutral (на разбеге) и момент передачи рук (bar_after) — 2 крыла x 2 склона. Под lock cpu.
L=tools/research/pilot-feedback-trim/liftoff
cd "$(dirname "$0")/../../../.." || exit 1
W=sport,ww_t2c
for an in 9 10 11 12 13 14 15 16; do
  $L/run.sh --wings=$W --slope=12,17 --post=25 --every=2 --alpha_neutral=$an --out=$L/out/scan_an$an.json
done
for b in 0.3 0.4 0.6 0.7 0.8 1.2 1.5; do
  $L/run.sh --wings=$W --slope=12,17 --post=25 --every=2 --bar_after=$b --upright_clear=100 --out=$L/out/scan_bar$b.json
done
