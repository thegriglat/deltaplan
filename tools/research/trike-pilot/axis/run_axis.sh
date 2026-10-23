#!/bin/bash
# TP-26: прогон осей винта. Из корня копии: .dpcli/dpcli lock cpu TP-26 -- tools/research/trike-pilot/axis/run_axis.sh [оси...]
# Для каждой оси временно подставляет cart.prop_axis_below_hang_m в configs/tow_tug.json, гоняет связку
# (tests/game/test_tow_trike_climb.gd) и инвариант (4)/(6) дельталёта (tests/contracts/test_trike_pilot_k6.gd),
# пишет полный вывод в build/research/trike-pilot/axis/axis_<ось>.log; config возвращается.
AXES=${@:-1.35 1.38 1.40 1.42 1.45}
CFG=configs/tow_tug.json
OUT=build/research/trike-pilot/axis
mkdir -p $OUT
cp $CFG $OUT/tow_tug.orig.json
trap 'cp $OUT/tow_tug.orig.json $CFG' EXIT
for a in $AXES; do
	sed -i -E "s/(\"prop_axis_below_hang_m\": )[0-9.]+/\1$a/" $CFG
	for f in tow_trike_climb trike_pilot_k6; do
		XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tests/run_tests.tscn -- --filter=$f > $OUT/axis_${a}_$f.log 2>&1
	done
	echo "=== ось $a"; grep -h "TT_CLIMB\|фугоида\|штанга на упоре\|горизонтальный полёт\|разбег\|FAIL\|check failed" $OUT/axis_${a}_*.log | cut -c1-400
done
