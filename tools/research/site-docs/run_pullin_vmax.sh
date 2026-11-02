#!/bin/bash
# SD-13: перемер Vmax «на себя» (обычный и с добором) на текущей игре по всем крыльям с блоком pendulum.
# Использует инструмент pullin_speed (случай vm4: normal, full); из корня копии. Итог — raw/raw_*.json,
# затем tools/research/site-docs/pullin_vmax.py → pullin_vmax.{json,md}.
cd "$(dirname "$0")/../../.."
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
O=tools/research/site-docs/raw
mkdir -p $O
ALL=$(ls configs/wings/*.json | xargs -n1 basename | sed 's/\.json//')
i=0
for w in $ALL; do
  python3 -c "import json,sys;sys.exit(0 if 'pendulum' in json.load(open('configs/wings/$w.json')) else 1)" || continue
  g=$((i % 8)); L[$g]="${L[$g]},$w"; i=$((i+1))
done
for g in 0 1 2 3 4 5 6 7; do
  godot --headless --path . res://tools/research/pullin_speed/pullin_speed.tscn -- --out=$O/raw_$g.json --wings=${L[$g]#,} --cases=vm4 > $O/log_$g.txt 2>&1 &
done
wait
