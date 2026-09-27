#!/usr/bin/env bash
# Матрица прогонов бота-маршрутника (карточка 02, FR-34a): 4 локации × {weak, medium, strong} ×
# ветер {0, 15 км/ч с запада} × 5 сидов × 40 км, с --clouds и без.
#   tools/atmosphere/xc_matrix.sh [каталог_результатов] [параллельность]
# По умолчанию пишет JSON'ы в tmp_xc_matrix/ (не в git). Параллельность по умолчанию — nproc/2 (godot тяжёлый).
# Направление ветра для всех локаций — 270° (запад), см. docs/research/xc_reference.md, раздел
# «Ветер локаций в матрице» (допущение, кроме Онгудая где подтверждено итогом 01).
#
# Каждый прогон обёрнут в `timeout` (WALL_TIMEOUT, c): подвисший/сверхдолгий процесс (например
# при гонке с параллельной правкой общих .gd-скриптов другой карточкой) не блокирует всю матрицу —
# результат помечается {"end_reason": "timeout"}. Пустой/битый вывод (скрипт-ошибка) — {"end_reason": "error"}.
# xc_report.py считает оба отдельным исходом, не «успех»/«посадка».
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT_DIR="${1:-tmp_xc_matrix}"
JOBS="${2:-$(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 ))}"
mkdir -p "$OUT_DIR"

# Подмножество матрицы и доп. флаги xc_run — через окружение (карточка 07), например
#   XC_WEATHERS="medium strong" XC_CLOUDS="0" XC_EXTRA="--ideal" tools/atmosphere/xc_matrix.sh tmp_ideal
read -r -a LOCATIONS <<<"${XC_LOCATIONS:-ongudai altai askarovo aushkul}"
read -r -a WEATHERS <<<"${XC_WEATHERS:-weak medium strong}"
read -r -a WINDS <<<"${XC_WINDS:-0 15}"
read -r -a SEEDS <<<"${XC_SEEDS:-1 2 3 4 5}"
read -r -a CLOUDS <<<"${XC_CLOUDS:-0 1}"
EXTRA="${XC_EXTRA:-}"
KM=40
TIME_LIMIT=3600
WIND_DEG=270
WALL_TIMEOUT=150

jobs_file="$(mktemp)"
job_dir="$(mktemp -d)"
trap 'rm -f "$jobs_file"; rm -rf "$job_dir"' EXIT

i=0
for loc in "${LOCATIONS[@]}"; do
	for w in "${WEATHERS[@]}"; do
		for wind in "${WINDS[@]}"; do
			for seed in "${SEEDS[@]}"; do
				for clouds in "${CLOUDS[@]}"; do
					tag="${loc}_${w}_wind${wind}_seed${seed}"
					flag=""
					if [[ $clouds == 1 ]]; then
						tag="${tag}_clouds"
						flag="--clouds"
					else
						tag="${tag}_noclouds"
					fi
					out="$OUT_DIR/$tag.json"
					log="$OUT_DIR/$tag.log"
					i=$((i + 1))
					wrapper="$job_dir/job_$i.sh"
					cat >"$wrapper" <<EOF
#!/usr/bin/env bash
out="$out"
log="$log"
if ! timeout $WALL_TIMEOUT tools/atmosphere/xc_run.sh --location=$loc --weather=$w --seed=$seed \\
		--wind=$wind,$WIND_DEG --km=$KM --time-limit=$TIME_LIMIT --out="\$out" $flag $EXTRA >"\$log" 2>&1; then
	ec=\$?
	if [[ \$ec -eq 124 ]]; then
		printf '{"end_reason": "timeout"}\n' >"\$out"
		echo "xc_matrix: TIMEOUT после ${WALL_TIMEOUT} с" >>"\$log"
	fi
fi
if [[ ! -s "\$out" ]] || ! python3 -c "
import json, sys
d = json.load(open('\$out'))
sys.exit(0 if d.get('end_reason') else 1)
" >/dev/null 2>&1; then
	printf '{"end_reason": "error"}\n' >"\$out"
	echo "xc_matrix: пустой/битый результат, помечено error" >>"\$log"
fi
EOF
					echo "bash $wrapper" >>"$jobs_file"
				done
			done
		done
	done
done

n=$(wc -l <"$jobs_file")
echo "xc_matrix: $n прогонов (timeout ${WALL_TIMEOUT} с/прогон), параллельность $JOBS, результаты в $OUT_DIR/"
t0=$(date +%s)
xargs -a "$jobs_file" -d '\n' -P "$JOBS" -I{} bash -c '{}'
t1=$(date +%s)
echo "xc_matrix: готово за $(( (t1 - t0) / 60 )) мин $(( (t1 - t0) % 60 )) с"
