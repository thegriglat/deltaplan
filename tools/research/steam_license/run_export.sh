#!/usr/bin/env bash
# Настоящий экспорт всех пресетов (debug, как tools/build.sh) в build/exp_check/ — что лежит рядом с исполняемым файлом.
set -euo pipefail
export XDG_DATA_HOME="$(mktemp -d)"
mkdir -p "$XDG_DATA_HOME/godot"
ln -s "$HOME/.local/share/godot/export_templates" "$XDG_DATA_HOME/godot/export_templates"
cp project.godot build/.project.godot.bak
rm -rf build/exp_check; mkdir -p build/exp_check/linux build/exp_check/windows build/exp_check/macos
godot --headless --path . --export-debug Linux build/exp_check/linux/deltaplan.x86_64 2>&1 | tail -3
godot --headless --path . --export-debug Windows build/exp_check/windows/deltaplan.exe 2>&1 | tail -3
godot --headless --path . --export-debug macOS build/exp_check/macos/deltaplan.zip 2>&1 | tail -3
cp build/.project.godot.bak project.godot
rm -rf "$XDG_DATA_HOME"
find build/exp_check -type f | xargs ls -l
