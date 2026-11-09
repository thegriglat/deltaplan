#!/usr/bin/env bash
# run_pins.sh <sha> <A|B>...: зонд стартов в фиксированных точках (pins<A|B>.json)
d=$(cd "$(dirname "$0")" && pwd)
O=$HOME/worktrees/deltaplan/picard-terrain-PT-14/tools/research/picard_terrain/out/PT-14
sha=$1; shift
for t in "$@"; do
  PT14_PINS=$O/pins$t.json $d/run_starts.sh $sha starts_pin$t
done
