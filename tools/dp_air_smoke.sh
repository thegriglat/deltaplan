#!/usr/bin/env bash
# Дымовой тест поставки DpAir (W9): release-расширение + экспорт Linux + запуск экспортированного
# бинаря headless сценой addons/dp_air/smoke.tscn (подмена главной сцены — override.cfg). Всё во временных каталогах/профиле.
# Нужны шаблоны экспорта Godot в ~/.local/share/godot/export_templates (как у tools/build.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
tools/build_rust.sh release linux
out="$(mktemp -d)"
xdg="$(mktemp -d)"
trap 'rm -rf "$out" "$xdg"; git checkout -- project.godot 2>/dev/null || true' EXIT
export XDG_DATA_HOME="$xdg"
tpl="$HOME/.local/share/godot/export_templates"
if [[ -d "$tpl" ]]; then
	mkdir -p "$xdg/godot"
	ln -s "$tpl" "$xdg/godot/export_templates"
fi
# первый --import проекта с расширением падает — импорт дважды
godot --headless --path . --import >/dev/null 2>&1 || true
godot --headless --path . --import >/dev/null 2>&1 || true
cp project.godot "$out/project.godot.bak"
godot --headless --path . --export-release Linux "$out/deltaplan.x86_64" >"$out/export.log" 2>&1 || {
	tail -20 "$out/export.log" >&2; echo "экспорт не удался" >&2; exit 1; }
cmp -s project.godot "$out/project.godot.bak" || cp "$out/project.godot.bak" project.godot
ls "$out"
log="$out/run.log"
# Релизный шаблон не принимает ни -s, ни путь сцены в командной строке (path overrides выключены) —
# главную сцену подменяет override.cfg рядом с бинарём.
printf '[application]\nrun/main_scene="res://addons/dp_air/smoke.tscn"\n' > "$out/override.cfg"
(cd "$out" && timeout 60 ./deltaplan.x86_64 --headless) >"$log" 2>&1 && rc=0 || rc=$?
cat "$log"
if [[ $rc -eq 0 ]] && grep -q '^DP_AIR_SMOKE OK' "$log"; then
	echo "SMOKE OK"
else
	echo "SMOKE FAIL (код $rc)" >&2
	exit 1
fi
