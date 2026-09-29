#!/usr/bin/env bash
# Локальная проверка проекта (вместо CI): линтер, тесты, сборка Linux, smoke-запуск сборки.
# tools/check.sh [--no-build] [--filter=подстрока]   (аргументы в любом порядке)
# Все запуски Godot и игры идут с временным профилем (XDG_DATA_HOME), настоящий не трогается.
# С --filter: только тесты с подстрокой в имени; сборка и линтер пропускаются (быстрый прогон).
set -uo pipefail
cd "$(dirname "$0")/.."

no_build=0
filter=""
for a in "$@"; do
	case "$a" in
		--no-build) no_build=1 ;;
		--filter=*) filter="${a#--filter=}"; no_build=1 ;;
		*) echo "Неизвестный аргумент: $a" >&2
		   echo "Использование: tools/check.sh [--no-build] [--filter=подстрока]" >&2
		   exit 2 ;;
	esac
done

XDG_DATA_HOME=$(mktemp -d)
export XDG_DATA_HOME
# шаблоны экспорта — из настоящего профиля симлинком (только чтение), иначе сборка их не найдёт
real_templates="$HOME/.local/share/godot/export_templates"
if [[ -d "$real_templates" ]]; then
	mkdir -p "$XDG_DATA_HOME/godot"
	ln -s "$real_templates" "$XDG_DATA_HOME/godot/export_templates"
fi
project_clean=0
git diff --quiet -- project.godot && project_clean=1
cleanup() {
	rm -rf "$XDG_DATA_HOME"
	# импорт мог переписать project.godot — вернуть, если до запуска он был чистым
	if [[ $project_clean == 1 ]]; then git checkout -- project.godot 2>/dev/null || true; fi
}
trap cleanup EXIT

fail=0
step() { echo; echo "== $1"; }

step "Импорт ресурсов"
godot --headless --path . --import >/dev/null 2>&1 || true

if [[ -z "$filter" ]]; then
	step "Линтер"
	tools/lint.sh || fail=1
fi

step "Тесты"
targs=()
[[ -n "$filter" ]] && targs=(-- "--filter=$filter")
out=$(godot --headless --path . res://tests/run_tests.tscn "${targs[@]}" 2>&1)
echo "$out" | grep -E "FAIL|тестов" || true
echo "$out" | grep -q " 0 упало" || fail=1

if [[ $no_build == 0 ]]; then
	step "Сборка Linux"
	tools/build.sh linux >/dev/null 2>&1 || fail=1
	step "Smoke-запуск сборки"
	build/linux/deltaplan.x86_64 --headless -- --smoke 2>&1 | grep smoke || fail=1
fi

echo
if [[ $fail == 0 ]]; then echo "ПРОВЕРКА ПРОЙДЕНА"; else echo "ПРОВЕРКА НЕ ПРОЙДЕНА"; fi
exit $fail
