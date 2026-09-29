#!/bin/sh
# AM-09: остаток прогонов одним заходом (после прогонов Askervein и выгрузки полей):
#  1) GPU под одним замком: слова пилота (synth.py 4/5/6 при λ/h калибровки и AM-01), поля у
#     подветренных стартов AM-00 с параметрами калибровки (lee_fields.py);
#  2) Godot headless: ТКЭ на мачтах Askervein (turb_askervein.gd), провалы за гребнем (turb_probe --only=lee);
#  3) сводки: fit_s1.py, fit_s3.py, validate_s23.py.
# Из корня копии: sh tools/research/tune/run_rest.sh > tools/research/tune/out/run_rest.log 2>&1
set -e
T=tools/research/tune
PY=$PWD/$T/.venv/bin/python
flock /tmp/heat_ca_gpu.lock sh -c "cd $T && $PY pilot_check.py && cd ../air3d && $PY ../air_turb/lee_fields.py"
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . -s $T/turb_askervein.gd -- \
  --points=$T/out/tke_points.json --out=$T/out/tke_model.json \
  $T/fields/ask_12p5_best $T/fields/ask_25_best $T/fields/ask_50a_best $T/fields/ask_12p5_nom
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/research/air_turb/turb_probe.tscn -- \
  --only=lee --out=$T/out/lee
cd $T
$PY fit_s1.py
$PY fit_s3.py
$PY validate_s23.py
echo "run_rest: готово"
