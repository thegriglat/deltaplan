#!/bin/sh
# AM-09б: пробы при λ/h = 0,25 с согласованным масштабом 3 (λ = max(40 м, λ/h·h), h нейтр. = 0,3 u*/f)
# одной пачкой. Шаги пишутся в out/am09b/steps.jsonl (по строке на шаг); повторный запуск
# пропускает сделанные шаги. Из корня копии:
#   /home/greg/deltaplan/tools/job.sh start am09b-probes 14400 sh tools/research/tune/run_am09b.sh
# Поля (вне git): tools/research/air_thermals/fields, air_turb/fields, tune/fields.
# Итог — am09b_summary.py (таблица «0,1 → 0,25»).
set -e
ROOT=$PWD
T=tools/research/tune
PY=$ROOT/$T/.venv/bin/python
LOCK="flock /tmp/heat_ca_gpu.lock"
O=$ROOT/$T/out/am09b
mkdir -p "$O"
STEPS=$O/steps.jsonl
touch "$STEPS"

step() {
	name=$1
	shift
	if grep -q "\"$name\"" "$STEPS"; then
		echo "== $name: уже сделано"
		return 0
	fi
	echo "== $name: $*"
	t0=$(date +%s)
	(cd "$ROOT" && sh -c "$*")
	echo "{\"step\": \"$name\", \"s\": $(($(date +%s) - t0))}" >> "$STEPS"
}

godot_run() {
	echo "XDG_DATA_HOME=\$(mktemp -d) godot --headless --path . $*"
}

# 1) поля масштаба 1 при λ/h = 0,25 (air.py Params по умолчанию); make_fields.py в конце обрезает
#    фикстуры тестов термиков — их не меняем (git checkout)
for c in h12 h15 h09; do
	step "fields_thermals_$c" "cd tools/research/air_thermals && $LOCK $PY make_fields.py --cases $c; cd $ROOT && git checkout -- tests/atmosphere/fixtures/air_model/thermals"
done
step lee_fields "cd tools/research/air3d && $LOCK $PY ../air_turb/lee_fields.py"
for a in "ask_25_best --dx 25 --lam_frac 0.25 --z0 0.042" "ask_50a_best --dx 50 --adv1 --lam_frac 0.25 --z0 0.042" \
	"ask_12p5_best --dx 12.5 --lam_frac 0.25 --z0 0.042" "ask_12p5_nom --dx 12.5 --lam_frac 0.1 --z0 0.03"; do
	n=${a%% *}
	step "askervein_$n" "cd $T && $LOCK $PY askervein_fields.py fields/$a"
done

# 2) масштаб 3 (Godot headless): ТКЭ на мачтах Askervein, провалы за гребнем, таблица σ, спектр
step turb_askervein "$(godot_run -s $T/turb_askervein.gd -- --points=$T/out/tke_points.json --out=$T/out/tke_model.json \
	$T/fields/ask_12p5_best $T/fields/ask_25_best $T/fields/ask_50a_best $T/fields/ask_12p5_nom)"
for o in lee table spectrum; do
	step "turb_probe_$o" "$(godot_run res://tools/research/air_turb/turb_probe.tscn -- --only=$o)"
done
step spectrum "$PY tools/research/air_turb/spectrum.py --fmin 0.1 --fmax 1.0"

# 3) масштаб 2: пробы термиков (~1 ч), картинки
step thermals_probe "$(godot_run res://tools/research/air_thermals/probe.tscn) > $O/thermals_probe.log 2>&1"
step thermals_figs "cd tools/research/air_thermals && $PY figs.py"

# 4) сводки AM-09 (масштаб 3 по ТКЭ Askervein, проверки масштабов 2–3) и итог AM-09б
step fits "cd $T && $PY fit_s3.py > out/fit_s3.log 2>&1 && $PY validate_s23.py"
$PY $T/am09b_summary.py
echo "run_am09b: готово"
