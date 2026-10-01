#!/bin/sh
# Моррис модели воздуха: план + все прогоны одной пачкой в фоне (tools/job.sh), итог — analyze.py.
# Из корня копии:
#   sh tools/research/morris/run_all.sh [r]         — планы (если их нет) и запуск пачек
#       «morris»    — масштаб 1 (air.py на GPU), 6 случаев × (r·17 + 1) точек;
#       «morris-s3» — масштаб 3 (поля Askervein → Godot headless), 160 точек × 3 поля
#   /home/greg/deltaplan/tools/job.sh wait morris 28800; /home/greg/deltaplan/tools/job.sh wait morris-s3 7200
#   tools/research/tune/.venv/bin/python tools/research/morris/analyze.py
# Прогоны дописываются в out/runs/<случай>.jsonl; повторный запуск продолжает с места (готовые точки
# пропускаются). Замок GPU (/tmp/heat_ca_gpu.lock) берётся на каждую точку внутри run_points.py.
set -e
R=${1:-12}
ROOT=$PWD
M=$ROOT/tools/research/morris
PY=$ROOT/tools/research/tune/.venv/bin/python
cd "$M"
[ -f out/plan.json ] || $PY plan.py --r "$R" --seed 1
/home/greg/deltaplan/tools/job.sh start morris 28800 $PY run_points.py
cd "$ROOT"
/home/greg/deltaplan/tools/job.sh start morris-s3 7200 sh tools/research/morris/run_s3.sh
