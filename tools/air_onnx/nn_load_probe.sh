#!/usr/bin/env bash
# ON-5: загрузка места с engine = nn (headless, без GPU): строка журнала air_model и время этапа с разбивкой.
# Использование: tools/air_onnx/nn_load_probe.sh <model.onnx> [место] [час] [ветер м/с] [откуда °]
cd "$(dirname "$0")/../.." || exit 1
model="${1:?нужен путь к .onnx}"
shift
XDG_DATA_HOME=$(mktemp -d) exec godot --headless --path . res://tools/air_onnx/nn_load_probe.tscn \
  -- --air-nn-model="$model" "$@" 2>&1
