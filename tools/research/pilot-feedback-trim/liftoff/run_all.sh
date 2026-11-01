#!/bin/bash
# Основной прогон PFT-4: база и подмена факторов (всё в сценарии, код игры не правится). Из корня копии; под lock cpu.
L=tools/research/pilot-feedback-trim/liftoff
cd "$(dirname "$0")/../../../.." || exit 1
W=sport,ww_t2c,moyes_litespeed_rx,training
S=12,17
R=$L/run.sh
$R --wings=$W --slope=$S --post=25 --out=$L/out/base.json
$R --wings=$W --slope=$S --post=25 --alpha_neutral=trim --out=$L/out/an_trim.json
$R --wings=$W --slope=$S --post=25 --bar_after=0 --upright_clear=100 --out=$L/out/bar0.json
$R --wings=$W --slope=$S --post=25 --bar_after=0.5 --upright_clear=100 --out=$L/out/bar05.json
$R --wings=$W --slope=$S --post=25 --bar_after=2 --upright_clear=100 --out=$L/out/bar2.json
$R --wings=$W --slope=$S --post=25 --bar_after=3 --upright_clear=100 --out=$L/out/bar3.json
$R --wings=$W --slope=$S --post=25 --alpha_neutral=trim --bar_after=0 --upright_clear=100 --out=$L/out/an_trim_bar0.json
# эталон фугоиды: старт в воздухе с отклонением скорости от трима (V0, км/ч)
for v in 33 36 38 40 42 45; do $R --mode=air --wings=$W --v0=$v --post=40 --out=$L/out/air_$v.json; done
