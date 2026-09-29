#!/usr/bin/env bash
# tools/soak.sh — соак-прогон собранной Linux-сборки по матрице крылья × локации × погода
# (ветер в лоб старту): для каждого сочетания --autostart --autopilot под xvfb, код выхода + лог на
# ERROR/SCRIPT ERROR. Требует tools/build.sh linux.
#
# Godot сам не завершает процесс по --time= (это работает только вместе со --screenshot),
# поэтому длительность соака задаёт снаружи `timeout`: убитый по таймауту процесс (код 124/137)
# после TIME_S секунд — ожидаемое завершение соака, не ошибка; ошибка — это ранний иной выход
# или строка ERROR/SCRIPT ERROR в логе.
#
# SOAK_TIME_S=10 tools/soak.sh   — быстрая проверка скрипта на коротком прогоне.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="build/linux/deltaplan.x86_64"
TIME_S="${SOAK_TIME_S:-300}"
BUFFER_S=30
LOG_DIR="build/soak_logs"
mkdir -p "$LOG_DIR"

if [[ ! -x "$BIN" ]]; then
	echo "нет сборки: $BIN (сначала tools/build.sh linux)" >&2
	exit 1
fi

wings=(training sport laminar)
weathers=(weak medium strong)
# Прогноз погоды: --temp=<°C> --wind=<м/с> (слабый +20 °C / 7 км/ч, средний +26 / 11, сильный +31 / 18).
declare -A forecast=(
	[weak]="--temp=20 --wind=1.9444"
	[medium]="--temp=26 --wind=3.0556"
	[strong]="--temp=31 --wind=5"
)
mapfile -t locations < <(cd configs/locations && ls ./*.json | xargs -n1 basename -s .json | sort)

fail=0
rows=()

for loc in "${locations[@]}"; do
	for wing in "${wings[@]}"; do
		for weather in "${weathers[@]}"; do
			combo="$loc × wings/$wing × $weather × в лоб"
			log="$LOG_DIR/${loc}_${wing}_${weather}.log"
			xvfb-run -a timeout "$((TIME_S + BUFFER_S))" "$BIN" --headless -- \
				--autostart --autopilot --location="$loc" --wing="$wing" ${forecast[$weather]} \
				--from=launch --time="$TIME_S" >"$log" 2>&1
			code=$?
			bad=0
			# 124/137 — соак сам оборвал процесс по таймауту после TIME_S с (норма).
			if [[ $code -ne 0 && $code -ne 124 && $code -ne 137 ]]; then
				bad=1
			fi
			if grep -qE "ERROR|SCRIPT ERROR" "$log"; then
				bad=1
			fi
			if [[ $bad -eq 0 ]]; then
				rows+=("$combo  ok")
			else
				rows+=("$combo  ОШИБКА (код $code, см. $log)")
				fail=1
			fi
		done
	done
done

echo
echo "== soak: ${#rows[@]} сочетаний =="
for r in "${rows[@]}"; do echo "  $r"; done
exit $fail
