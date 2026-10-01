#!/usr/bin/env bash
SP=/home/greg/projects/.tmp/claude-1000/-home-greg-deltaplan/55d419f6-4839-418d-8f65-ded00754411a/scratchpad
OUT=$HOME/cf1out/runcap; mkdir -p $OUT
export CF1_OUT=$OUT CF1_CASES="atlas:0,sport:0,combat:0,training:0,slavutich_ut:0,atlas:10.8,sport:10.8" CF1_SCENS="run_neutral,run_pull" CF1_SEEDS="0,1500" CF1_POST=6
cd /home/greg/deltaplan-control-fix-cf1
wt=$HOME/deltaplan-cf1-bisect-base; [ -d $wt ] || { git worktree add --detach $wt d3f01bb >/dev/null 2>&1; XDG_DATA_HOME=$(mktemp -d) timeout 900 godot --headless --path $wt --import >/dev/null 2>&1; }
for pair in "base:$wt" "fix:/home/greg/deltaplan-control-fix-cf1"; do
  t=${pair%%:*}; d=${pair#*:}
  cp $SP/test_cf1probe_v2.gd $d/tests/game/test_cf1probe.gd
  CF1_TAG=$t XDG_DATA_HOME=$(mktemp -d) timeout 2400 godot --headless --path $d res://tests/run_tests.tscn -- --filter=cf1probe > $OUT/${t}_run.log 2>&1
  rm -f $d/tests/game/test_cf1probe.gd
  echo "done $t"
done
