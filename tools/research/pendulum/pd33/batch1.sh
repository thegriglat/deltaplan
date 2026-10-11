#!/bin/bash
# PD-33: пачка вариантов посадки (тест техники посадки × переменные окружения) → лог;
# сводка: python summ.py <лог> > variants_summary.txt. Запуск из корня копии.
run() { XDG_DATA_HOME=$(mktemp -d) systemd-run --user --scope -p MemoryMax=12G -q \
  godot --headless --path . res://tests/run_tests.tscn -- --filter=test_pendulum_landing_technique; }
while IFS='|' read -r name envs; do
  [ -z "$name" ] && continue
  echo "=== $name ($envs)"
  export -f run; env $envs bash -c run 2>&1 | grep -E "правильная|отдача с" | sed 's/^ *//'
done <<'LIST'
base|PD33_X=0
B06|PD27_PUSH=0.6
B06_strut800|PD27_PUSH=0.6 PD30_REACH=0 PD29_FMAX=800
B06_A|PD27_PUSH=0.6 PD29_DS=1
B06_A_strut800|PD27_PUSH=0.6 PD29_DS=1 PD30_REACH=0 PD29_FMAX=800
LIST
