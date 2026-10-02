#!/usr/bin/env bash
SP=/home/greg/projects/.tmp/claude-1000/-home-greg-deltaplan/55d419f6-4839-418d-8f65-ded00754411a/scratchpad
OUT=$HOME/cf1out/sweep; mkdir -p $OUT
export CF1_OUT=$OUT CF1_CASES="training:10.8,training:18,training:25,sport:18,sport:25,combat:25" CF1_SCENS="idle,run_neutral" CF1_SEEDS="0,1500,3000"
for c in 0ac895d 5f8990e head; do
  wt=$HOME/deltaplan-cf1-bisect-$c; [ $c = head ] && wt=$HOME/deltaplan-control-fix-cf1
  cp $SP/test_cf1probe.gd $wt/tests/game/
  [ -s $OUT/${c}_combat-25-3000-run_neutral.csv ] || CF1_TAG=$c XDG_DATA_HOME=$(mktemp -d) timeout 1800 godot --headless --path $wt res://tests/run_tests.tscn -- --filter=cf1probe > $OUT/${c}_run.log 2>&1
  echo "done $c $(date +%T)"
done
cd $HOME/deltaplan-control-fix-cf1 && cp project.godot /tmp/cf1_pg_head
[ -s $OUT/headgpu_combat-25-3000-run_neutral.csv ] || CF1_TAG=headgpu timeout 3000 tools/gpu_tests.sh --filter=cf1probe > $OUT/headgpu_run.log 2>&1
cp /tmp/cf1_pg_head project.godot
echo "done gpu $(date +%T)"
