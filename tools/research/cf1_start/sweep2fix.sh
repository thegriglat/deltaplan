#!/usr/bin/env bash
# CF-1 серия 2: Славутич/учебное/спорт × 0/3/6/10 м/с встречного, стоя и разбег (нейтр./↓/↑), 8 с после отрыва.
SP=/home/greg/projects/.tmp/claude-1000/-home-greg-deltaplan/55d419f6-4839-418d-8f65-ded00754411a/scratchpad
OUT=$HOME/cf1out/s2fix; mkdir -p $OUT
export CF1_OUT=$OUT CF1_CASES="slavutich_ut:0,slavutich_ut:10.8,slavutich_ut:21.6,slavutich_ut:36,training:0,training:10.8,training:21.6,training:36,sport:0,sport:10.8,sport:21.6,sport:36" CF1_SCENS="idle,run_neutral,run_pull,run_push" CF1_SEEDS="0,1500" CF1_POST=8
for c in ${VERSIONS:-0ac895d 5f8990e head}; do
  wt=$HOME/deltaplan-cf1-bisect-$c; [ $c = head ] && wt=$HOME/deltaplan-control-fix-cf1
  cp $SP/test_cf1probe_v2.gd $wt/tests/game/test_cf1probe.gd
  CF1_TAG=fix XDG_DATA_HOME=$(mktemp -d) timeout 2400 godot --headless --path $wt res://tests/run_tests.tscn -- --filter=cf1probe > $OUT/${c}_run.log 2>&1
  echo "done $c $(date +%T)"
done
if [ "${GPU:-1}" = 1 ]; then
  cd $HOME/deltaplan-control-fix-cf1 && cp project.godot /tmp/cf1_pg_head
  CF1_TAG=fixgpu timeout 4000 tools/gpu_tests.sh --filter=cf1probe > $OUT/headgpu_run.log 2>&1
  cp /tmp/cf1_pg_head project.godot
  echo "done gpu $(date +%T)"
fi
rm -f $HOME/deltaplan-control-fix-cf1/tests/game/test_cf1probe.gd
