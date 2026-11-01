#!/bin/bash
# Прогон по тегам: worktree ~/worktrees/deltaplan/pft1-<тег> (git worktree add --detach), файлы trim_batch.* и run.sh скопированы туда.
# usage: versions.sh <outdir> <тег...>
OUT=$(realpath "$1"); shift
mkdir -p "$OUT"
for t in "$@"; do
  d=~/worktrees/deltaplan/pft1-$t
  cd "$d" || continue
  export XDG_DATA_HOME=~/.cache/dp-xdg/pft1-$t
  mkdir -p "$XDG_DATA_HOME"; [ -d .godot ] || godot --headless --path . --import 2>&1 | grep -i "script error\|parse error" ; 
  W=""
  for w in sport moyes_litespeed_rx ww_t2c apogee training; do [ -f configs/wings/$w.json ] && W="$W,$w"; done; W=${W#,}
  L=tools/research/pilot-feedback-trim/longitudinal
  for ms in game ref; do
    $L/run.sh --mode=steady --wings=$W --hold=40 --shift=2 --mass=$ms --out=$OUT/${t}_steady_$ms.json 2>&1 | grep -i "script error\|parse error" ; 
  done
  $L/run.sh --mode=launch --wings=$W --slope=12,17 --out=$OUT/${t}_launch.json 2>&1 | grep -i "script error\|parse error" ; 
  $L/run.sh --mode=xtest --wings=$W --kinds=q-0.3,q0.3,bank30 --hows=X,instant --hold=40 --after=60 --out=$OUT/${t}_x.json 2>&1 | grep -i "script error\|parse error" ; 
  echo "done $t"
done
