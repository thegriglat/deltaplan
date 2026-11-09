#!/bin/bash
# PT-11: ядра термиков, баланс тепла, присутствие. Под lock cpu (после timing).
set -u
H=$(cd "$(dirname "$0")" && pwd)
O=$H/../out/PT-11
mkdir -p $O/thermals $O/presence
A=$HOME/worktrees/deltaplan/picard-terrain-PT-11
B=$HOME/worktrees/deltaplan/picard-terrain-PT-11-base
for c in ongudai_day_1 ongudai_day_2 ongudai_day_3; do
  for v in base after; do
    R=$A; [ $v = base ] && R=$B
    (cd $R && $HOME/.cache/dp-target/PT-11-probe-$v/target/release/pt11-probe cores tests/fixtures/wind/cases/$c.json) > $O/thermals/${v}_$c.jsonl 2> $O/thermals/${v}_$c.err
    echo "cores $v $c rc=$?"
  done
done
(cd $A && $HOME/.cache/dp-target/PT-11-probe-after/target/release/pt11-probe heat $A) > $O/heat_balance.json 2> $O/heat_balance.err
echo "heat rc=$?"
cd $H
for c in ongudai_strong synth_strong ongudai_storm; do
  python3 presence.py plan $c && python3 presence.py run $c && python3 presence.py analyze $c
  echo "presence $c rc=$?"
done
echo ALLDONE
