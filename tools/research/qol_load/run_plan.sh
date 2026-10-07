#!/bin/bash
# Весь план QL-6: 4 места x ветер 0/1/3/6 x 9:00/13:00, встречный ветер, T=26, ясно.
# Каждый замер — отдельный процесс Godot под замком GPU.
cd "$(dirname "$(readlink -f "$0")")"; D=$PWD
for loc in ongudai altai askarovo aushkul; do for h in 9 13; do for w in 0 1 3 6; do
  log=$D/logs/${loc}_w${w}_h${h}.log
  [ -f $log ] && grep -q '^exit=' $log && continue
  /home/greg/deltaplan/tools/dp lock gpu ql6-$loc-$w-$h -- ./run_one.sh $loc $w $h $log
done; done; done
python3 summarize.py
