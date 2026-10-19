#!/bin/bash
# VM-12 (VM-К7): 48 крыльев × случаи VM-К5 (8 процессов) + болтанка sport/laminar/training × 20 зёрен (3 процесса).
# Аргумент: 1 — после правки (release_event), 0 — до правки. Из корня копии; итог — out/vm12/r<arg>/raw_*.json,
# сводка — vm12_summary.py (после обоих прогонов).
cd "$(dirname "$0")/../../.."
R=${1:-1}
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
python3 tools/research/pullin_speed/turb_fields.py
O=tools/research/pullin_speed/out/vm12/r$R
mkdir -p $O
ALL=$(ls configs/wings/*.json | xargs -n1 basename | sed 's/\.json//')
i=0
for w in $ALL; do
  python3 -c "import json,sys;sys.exit(0 if 'pendulum' in json.load(open('configs/wings/$w.json')) else 1)" || continue
  g=$((i % 8)); L[$g]="${L[$g]},$w"; i=$((i+1))
done
for g in 0 1 2 3 4 5 6 7; do
  godot --headless --path . res://tools/research/pullin_speed/pullin_speed.tscn -- --out=$O/raw_$g.json --wings=${L[$g]#,} --cases=vm4 --relaxed=$R > $O/log_$g.txt 2>&1 &
done
for w in sport laminar training; do
  godot --headless --path . res://tools/research/pullin_speed/pullin_speed.tscn -- --out=$O/turb_$w.json --wings=$w --cases=turb --relaxed=$R --turb=tools/research/pullin_speed/out/vm12/turb_fields.json > $O/log_turb_$w.txt 2>&1 &
done
wait
