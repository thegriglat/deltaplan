#!/bin/bash
# Доп. случаи (pullcons) для всех крыльев, 8 процессов. Из любого каталога.
cd "$(dirname "$0")/../../.."
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
O=tools/research/pullin_speed/out
ALL=$(ls configs/wings/*.json | xargs -n1 basename | sed 's/\.json//')
i=0
for w in $ALL; do
  python3 -c "import json,sys;sys.exit(0 if 'pendulum' in json.load(open('configs/wings/$w.json')) else 1)" || continue
  g=$((i % 8)); L[$g]="${L[$g]},$w"; i=$((i+1))
done
for g in 0 1 2 3 4 5 6 7; do
  godot --headless --path . res://tools/research/pullin_speed/pullin_speed.tscn -- --out=$O/extra_$g.json --wings=${L[$g]#,} --cases=${CASES:-pullcons} > $O/logx_$g.txt 2>&1 &
done
wait
python3 tools/research/pullin_speed/merge.py
