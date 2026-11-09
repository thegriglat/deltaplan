#!/usr/bin/env bash
# run_patch2.sh: GD-тесты поля на копии с наброском (не сломан ли WindField без k1)
d=$(cd "$(dirname "$0")" && pwd)
for t in test_wind_field.gd test_air_model_atmo.gd test_debug_layers.gd test_air_field_contracts.gd test_air_field_import.gd; do
  $d/run_godot.sh patch ${t%.gd} "$t"
done
