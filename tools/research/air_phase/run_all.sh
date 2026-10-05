#!/usr/bin/env bash
# air-phase (P5): весь счёт одной командой — план (если нет) + все серии; продолжение после обрыва — той же командой.
# Запуск: /home/greg/deltaplan/tools/dp job --lock gpu start air-phase-run <таймаут_с> <копия>/tools/research/air_phase/run_all.sh
# Результаты: $AIR_SYNTH_DATA/phase/<plan>__<solver_version>/ ; прогресс: run_phase.py status --plan $AIR_SYNTH_DATA/phase/<plan>
set -euo pipefail
cd "$(dirname "$0")"
PY=${AP_PY:-/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python}
D=${AIR_SYNTH_DATA:-$HOME/air_synth_data}
NAME=${AP_PLAN:-ap_v1}
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-4}
[ -f "$D/phase/$NAME/plan.pb" ] || "$PY" run_phase.py plan --name "$NAME" --out "$D/phase"
exec "$PY" run_phase.py run --plan "$D/phase/$NAME" "$@"
