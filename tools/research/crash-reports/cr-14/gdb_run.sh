#!/usr/bin/env bash
# Запуск run.sh под gdb: весь вывод в файл. gdb_run.sh <лог> <аргументы repro...>
log="$1"; shift
cd "$(dirname "$0")/../../../.."
export XDG_DATA_HOME="$HOME/.cache/dp-xdg/$(basename "$PWD")" DISPLAY="${DISPLAY:-:0}"
pg=$(mktemp); cp project.godot "$pg"; trap 'cmp -s project.godot "$pg" || cp "$pg" project.godot; rm -f "$pg"' EXIT
gdb -batch -ex 'handle SIGPIPE nostop noprint pass' -ex run -ex 'thread apply all bt 30' -ex continue \
  --args godot --path . --audio-driver Dummy --resolution 1280x720 res://tools/research/crash-reports/cr-14/repro.tscn -- "$@" > "$log" 2>&1
