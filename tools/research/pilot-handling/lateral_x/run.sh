#!/bin/bash
# usage: run.sh <args...>  — запуск lateral_batch (вызывать под .dpcli/dpcli lock cpu)
cd "$(dirname "$0")/../../../.." || exit 1
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
exec godot --headless --path . res://tools/research/pilot-handling/lateral_x/lateral_batch.tscn -- "$@"
