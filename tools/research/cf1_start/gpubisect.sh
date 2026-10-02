#!/usr/bin/env bash
SP=/home/greg/projects/.tmp/claude-1000/-home-greg-deltaplan/55d419f6-4839-418d-8f65-ded00754411a/scratchpad
OUT=$HOME/cf1out/gpub; mkdir -p $OUT
export CF1_OUT=$OUT CF1_CASES="training:10.8,training:25" CF1_SCENS="idle,run_neutral" CF1_SEEDS="0,1500,3000"
cd /home/greg/deltaplan-control-fix-cf1
for c in 551e79b 041d8ed 0d1ecf2; do
  wt=$HOME/deltaplan-cf1-bisect-$c
  [ -d $wt ] || git worktree add --detach $wt $c >/dev/null 2>&1
  cp $SP/test_cf1probe.gd $wt/tests/game/
  [ -f $wt/.godot/imported_done ] || { XDG_DATA_HOME=$(mktemp -d) timeout 900 godot --headless --path $wt --import > $OUT/${c}_import.log 2>&1; touch $wt/.godot/imported_done; }
  cp $wt/project.godot /tmp/cf1_pg_$c
  (cd $wt && CF1_TAG=$c XDG_DATA_HOME=$(mktemp -d) timeout 2400 godot --path . --audio-driver Dummy --resolution 320x240 res://tests/run_tests.tscn -- --gpu --filter=cf1probe > $OUT/${c}_run.log 2>&1)
  cp /tmp/cf1_pg_$c $wt/project.godot
  echo "done $c $(date +%T)"
done
