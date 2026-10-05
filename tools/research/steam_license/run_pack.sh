#!/usr/bin/env bash
# Настоящий экспорт .pck для сверки эмуляции фильтров (SA-1). Запуск из корня копии проекта.
set -euo pipefail
export XDG_DATA_HOME="$(mktemp -d)"
mkdir -p "$XDG_DATA_HOME/godot"
ln -s "$HOME/.local/share/godot/export_templates" "$XDG_DATA_HOME/godot/export_templates"
cp project.godot build/.project.godot.bak
godot --headless --path . --import >/dev/null 2>&1 || true
for p in Linux Windows; do
  godot --headless --path . --export-pack "$p" "build/inv_check_$p.pck" 2>&1 | tail -5
done
cp build/.project.godot.bak project.godot
rm -rf "$XDG_DATA_HOME"
ls -la build/*.pck
