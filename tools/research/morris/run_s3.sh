#!/bin/sh
# Масштаб 3: поля Askervein в формате игры (λ/h 0,25, z0 0,042 — как AM-09б; вне git, fields/),
# план Морриса по параметрам atmosphere.json и прогон Godot headless (CPU). Из корня копии.
set -e
ROOT=$PWD
M=$ROOT/tools/research/morris
T=$ROOT/tools/research/tune
PY=$T/.venv/bin/python
mkdir -p "$M/fields"
cd "$T"
for a in "ask_25_best --dx 25 --lam_frac 0.25 --z0 0.042" "ask_50a_best --dx 50 --adv1 --lam_frac 0.25 --z0 0.042" \
	"ask_12p5_best --dx 12.5 --lam_frac 0.25 --z0 0.042"; do
	n=${a%% *}
	[ -f "$M/fields/$n.bin" ] || flock /tmp/heat_ca_gpu.lock $PY askervein_fields.py $M/fields/$a   # без кавычек: имя и флаги
done
cd "$M"
[ -f out/plan_s3.json ] || $PY s3_plan.py
cd "$ROOT"
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . -s tools/research/morris/turb_morris.gd -- \
	--points=tools/research/tune/out/tke_points.json --plan=tools/research/morris/out/plan_s3.json \
	--out=tools/research/morris/out/s3_runs.json \
	"$M/fields/ask_12p5_best" "$M/fields/ask_25_best" "$M/fields/ask_50a_best"
echo "run_s3: готово"
