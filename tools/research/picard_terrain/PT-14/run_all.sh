#!/usr/bin/env bash
# run_all.sh <sha>: бисекция — тесты Godot и зонды на одном коммите (под lock cpu снаружи)
set -uo pipefail
sha=$1
d=$(cd "$(dirname "$0")" && pwd)
R=$d/run_godot.sh
$R $sha import_pre "res://tests/atmosphere/probe_snap.gd" >/dev/null 2>&1   # прогрев импорта
$R $sha field_import "test_air_field_import.gd"
$R $sha probe_snap "--file=res://tests/atmosphere/probe_snap.gd"
$R $sha probe_ridge "--file=res://tests/atmosphere/probe_ridge.gd"
$R $sha lee_rotor "test_lee_rotor.gd"
$R $sha atmosphere "/test_atmosphere.gd"
$R $sha probe_starts "--file=res://tests/atmosphere/probe_starts.gd"
