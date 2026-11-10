#!/usr/bin/env bash
# run_ridge2.sh <sha>: probe_ridge (разложение, полёт с разными x_meas, дисперсии)
d=$(cd "$(dirname "$0")" && pwd)
$d/run_godot.sh $1 ridge2 "--file=res://tests/atmosphere/probe_ridge.gd"
