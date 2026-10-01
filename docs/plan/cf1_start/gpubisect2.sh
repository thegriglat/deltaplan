#!/usr/bin/env bash
SP=/home/greg/projects/.tmp/claude-1000/-home-greg-deltaplan/55d419f6-4839-418d-8f65-ded00754411a/scratchpad
OUT=$HOME/cf1out/gpub2; mkdir -p $OUT
export CF1_OUT=$OUT CF1_CASES="training:10.8,slavutich_ut:21.6" CF1_SCENS="idle,run_neutral" CF1_SEEDS="0" CF1_POST=8
cd /home/greg/deltaplan-control-fix-cf1
for c in "$@"; do
  wt=$HOME/deltaplan-cf1-bisect-$c
  [ -d $wt ] || git worktree add --detach $wt $c >/dev/null 2>&1
  cp $SP/test_cf1probe_v2.gd $wt/tests/game/test_cf1probe.gd
  [ -f $wt/.godot/imported_done ] || { XDG_DATA_HOME=$(mktemp -d) timeout 900 godot --headless --path $wt --import > $OUT/${c}_import.log 2>&1; touch $wt/.godot/imported_done; }
  cp $wt/project.godot /tmp/cf1_pg_$c
  (cd $wt && CF1_TAG=$c XDG_DATA_HOME=$(mktemp -d) timeout 2400 godot --path . --audio-driver Dummy --resolution 320x240 res://tests/run_tests.tscn -- --gpu --filter=cf1probe > $OUT/${c}_run.log 2>&1)
  cp /tmp/cf1_pg_$c $wt/project.godot
  echo "done $c $(date +%T)"
done
