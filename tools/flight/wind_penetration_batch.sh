#!/usr/bin/env bash
# WPC-3: вся пачка полётов против ветра и в динамике (контракт К6) одним прогоном, с продолжением
# с места (готовые ключи в build/wpc3/parts/*.csv пропускаются, готовые поля не пересчитываются).
#   tools/flight/wind_penetration_batch.sh            # аналитика + поле
#   tools/flight/wind_penetration_batch.sh analytic   # только аналитика
# 1) аналитика: 4 старта параллельно (headless), все крылья;
# 2) поле: расчёт на GPU (окно 320×240, замок /tmp/heat_ca_gpu.lock держится только на расчёт),
#    затем полёты по сохранённым полям (headless, 4 старта параллельно), крылья FIELD_WINGS;
# 3) сборка tools/research/wing_physics_check/out/penetration.csv и сводки (wind_penetration_table.py).
set -uo pipefail
cd "$(dirname "$0")/../.."
SITES=(altai/sinyukha_west askarovo/biyagoda_west aushkul/aushtau_east ongudai/kayancha_south)
FIELD_WINGS=${FIELD_WINGS:-slavutich_ut,training,laminar,combat}
PARTS=build/wpc3/parts
mkdir -p "$PARTS"
what=${1:-all}
t0=$(date +%s)

fly() { # mode site [доп. ключи]
	local mode=$1 site=$2
	shift 2
	XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/flight/wind_penetration_run.tscn \
		-- --mode="$mode" --sites="$site" --csv="$PARTS/${mode}_${site/\//_}.csv" "$@" \
		> "$PARTS/${mode}_${site/\//_}.log" 2>&1
}

for s in "${SITES[@]}"; do fly analytic "$s" & done
wait
echo "аналитика: $(($(date +%s) - t0)) с"

if [[ $what == all ]]; then
	t1=$(date +%s)
	pg=$(mktemp)
	cp project.godot "$pg"
	flock /tmp/heat_ca_gpu.lock env XDG_DATA_HOME="$(mktemp -d)" godot --path . \
		--resolution 320x240 --audio-driver Dummy res://tools/flight/wind_penetration_run.tscn \
		-- --phase=fields > "$PARTS/fields.log" 2>&1
	cmp -s project.godot "$pg" || cp "$pg" project.godot
	rm -f "$pg"
	echo "поле: расчёт $(($(date +%s) - t1)) с (с ожиданием замка)"
	for s in "${SITES[@]}"; do fly field "$s" --wings="$FIELD_WINGS" & done
	wait
	echo "поле: всего $(($(date +%s) - t1)) с"
fi
python3 tools/flight/wind_penetration_table.py --merge "$PARTS"/*.csv
echo "пачка: $(($(date +%s) - t0)) с"
