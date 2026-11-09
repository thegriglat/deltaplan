#!/usr/bin/env bash
# run_patch.sh: тест снимка и зонд на копии 9d94bf30c с набросом patch_snapshot.patch
d=$(cd "$(dirname "$0")" && pwd)
$d/run_godot.sh patch field_import "test_air_field_import.gd"
$d/run_godot.sh patch probe_snap "--file=res://tests/atmosphere/probe_snap.gd"
