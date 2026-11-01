#!/bin/bash
# usage: run.sh <name> <args...>  — запуск trim_batch под lock cpu
cd "$(dirname "$0")/../../../.." || exit 1
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
exec godot --headless --path . res://tools/research/pilot-feedback-trim/longitudinal/trim_batch.tscn -- "$@"
