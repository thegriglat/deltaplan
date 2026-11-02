#!/bin/bash
# Основной прогон PFT-1 (после steady_*.json, x_head.json, x_part.json, launch_head.json — см. README)
L=tools/research/pilot-feedback-trim/longitudinal
cd "$(dirname "$0")/../../../.." || exit 1
W=sport,moyes_litespeed_rx,ww_t2c,apogee,training
$L/run.sh --mode=xtest --wings=$W --kinds=q-0.4,bank30 --hows=X0.2,X1,X2,X4 --hold=60 --after=90 --out=$L/out/x_tau.json
$L/run.sh --mode=xtest --wings=$W --kinds=q-0.4,bank30 --hows=X0.2 --release_event=0 --hold=60 --after=90 --out=$L/out/x_norelease.json
$L/versions.sh $L/out/versions v1.5.15 v1.5.20 v1.5.21 v1.6.0 v1.7.0
