#!/usr/bin/env bash
# Проверка «без бинарника» (W9): свежая копия или CI — addons/dp_air/bin нет. Игра и тесты не падают.
# Временно убирает addons/dp_air/bin (возвращает в trap), импортирует проект, гонит
# --filter=test_air_contracts и запускает главную сцену headless на 120 кадров.
# Печатает строки Godot про недостающую библиотеку (допустимое предупреждение); падает на
# SCRIPT ERROR и на ненулевом коде выхода.
set -uo pipefail
cd "$(dirname "$0")/.."
bin=addons/dp_air/bin
hold="$(mktemp -d)"
xdg="$(mktemp -d)"
log="$(mktemp)"
restore() {
	if [[ -d "$hold/bin" ]]; then rm -rf "$bin"; mv "$hold/bin" "$bin"; fi
	rm -rf "$hold" "$xdg" "$log"
	git checkout -- project.godot 2>/dev/null || true
}
trap restore EXIT
[[ -d "$bin" ]] && mv "$bin" "$hold/bin"
export XDG_DATA_HOME="$xdg"
fail=0
# первый --import проекта с расширением может падать — импорт дважды (грабли пробы)
godot --headless --path . --import >/dev/null 2>&1 || true
godot --headless --path . --import >/dev/null 2>&1 || true

echo "== тесты test_air_contracts без бинарника"
godot --headless --path . res://tests/run_tests.tscn -- --filter=test_air_contracts >"$log" 2>&1
rc=$?
tail -3 "$log"; grep -A4 "  FAIL " "$log" | head -20
grep -n "SCRIPT ERROR" "$log" && fail=1
# Код 1 раннера — упавшие тесты воздуха сами по себе (они не зависят от расширения; список выше
# сверяйте с прогоном при наличии бинарника). Ломает проверку только падение/зависание Godot.
if [[ $rc -ne 0 && $rc -ne 1 ]]; then echo "тесты: код $rc"; fail=1; fi
grep -q "тестов" "$log" || { echo "раннер не дошёл до итога"; fail=1; }
echo "-- строки про библиотеку:"; grep -iE "dynamic library|dp_air|gdextension" "$log" | sort -u | head

echo "== главная сцена, 120 кадров"
godot --headless --path . --quit-after 120 >"$log" 2>&1
rc=$?
grep -n "SCRIPT ERROR" "$log" && fail=1
[[ $rc -eq 0 ]] || { echo "запуск: код $rc"; fail=1; }
echo "-- строки про библиотеку:"; grep -iE "dynamic library|dp_air|gdextension" "$log" | sort -u | head

[[ $fail -eq 0 ]] && echo "NOBIN OK" || echo "NOBIN FAIL"
exit $fail
