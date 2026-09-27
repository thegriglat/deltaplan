#!/usr/bin/env bash
# Локальная проверка проекта (вместо CI): линтер, тесты, сборка Linux, smoke-запуск сборки.
# tools/check.sh [--no-build]
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
step() { echo; echo "== $1"; }

step "Импорт ресурсов"
godot --headless --path . --import >/dev/null 2>&1 || true

step "Линтер"
tools/lint.sh || fail=1

step "Тесты"
out=$(godot --headless --path . res://tests/run_tests.tscn 2>&1)
echo "$out" | grep -E "FAIL|тестов" || true
echo "$out" | grep -q " 0 упало" || fail=1

if [[ "${1:-}" != "--no-build" ]]; then
	step "Сборка Linux"
	tools/build.sh linux >/dev/null 2>&1 || fail=1
	step "Smoke-запуск сборки"
	build/linux/deltaplan.x86_64 --headless -- --smoke 2>&1 | grep smoke || fail=1
fi

echo
if [[ $fail == 0 ]]; then echo "ПРОВЕРКА ПРОЙДЕНА"; else echo "ПРОВЕРКА НЕ ПРОЙДЕНА"; fi
exit $fail
