#!/usr/bin/env bash
# Пилот air-nn одной командой (для tmux): досчёт набора → подготовка → обучение → кривая (в) → оценка → отчёт.
#   ./run_pilot.sh                 — полный пилот (продолжение с места при повторе)
#   ./run_pilot.sh --smoke         — мини-прогон до отчёта (свои каталоги, основной набор и прогоны не трогает)
#   ./run_pilot.sh --name ИМЯ      — новый прогон с нуля (набор и кеш подготовки — те же)
#   ./run_pilot.sh status [--smoke] [--name ИМЯ]
# Коды выхода: 0 — отчёт готов; 1 — ошибка; 2 — неверные аргументы; 3 — нет места на диске; 4 — нет/мало данных;
#              130 — прерван SIGINT (Ctrl-C), 143 — прерван SIGTERM. Повтор той же команды продолжает.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -x "$HERE/.venv/bin/python" ]] || { echo "нет окружения: $HERE/setup_env.sh"; exit 1; }
export AIR_NN_DATA="${AIR_NN_DATA:-/home/greg/air_nn_data}"
exec "$HERE/.venv/bin/python" "$HERE/pilot.py" "$@"
