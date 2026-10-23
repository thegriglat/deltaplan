#!/usr/bin/env bash
# Проба gdext + Godot 4.7.2: сборка и запуск headless. Профиль Godot — временный.
# Использование: run.sh [debug|release]   (release — fat LTO, codegen-units=1, panic=abort; собирается дольше)
set -euo pipefail
cd "$(dirname "$0")"
mode="${1:-debug}"
if [[ "$mode" == release ]]; then (cd rust && cargo build --release); else (cd rust && cargo build); fi
lib="$PWD/rust/target/$mode/libgdext_probe.so"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp godot/main.gd godot/main.tscn godot/project.godot "$tmp/"
# редакторный godot грузит ключ linux.debug; release-библиотеку подставляем под него
cat > "$tmp/gdext_probe.gdextension" <<EOT
[configuration]
entry_symbol = "gdext_rust_init"
compatibility_minimum = 4.7
reloadable = false

[libraries]
linux.debug.x86_64 = "$lib"
linux.release.x86_64 = "$lib"
EOT
export XDG_DATA_HOME="$tmp/xdg"
cd "$tmp"
# первый --import в чистом проекте: расширение ещё не известно, процесс падает (SIGABRT); второй проходит
godot --headless --path . --import >/dev/null 2>&1 || true
godot --headless --path . --import >/dev/null 2>&1
godot --headless --path . 2>&1 | grep -v '^\s*$'
