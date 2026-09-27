#!/usr/bin/env bash
# 11-02: главное меню, пауза, настройки, «Об игре», итог (мягкая посадка и авария) — 6 кадров.
# Кадр — tools/shots/ui_shot.tscn (фон за меню, без полного полёта — быстрее и устойчивее).
# tools/shots/ui.sh [выход]   (по умолчанию docs/screenshots/ui)
set -uo pipefail
cd "$(dirname "$0")/../.."

out="${1:-docs/screenshots/ui}"
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"

timeout 120 godot --path . --audio-driver Dummy --resolution 1920x1080 \
	res://tools/shots/ui_shot.tscn -- "--out=$out"
code=$?

echo
if [[ $code == 0 ]]; then
	echo "ui.sh: готово, кадры в $out"
else
	echo "ui.sh: ошибка (код $code)"
fi
exit $code
