#!/usr/bin/env bash
# run_patch3.sh <sha>: правленные тесты подветренной зоны (patch_tests_lee.patch) на коммите; патч применяется во временной копии patch
d=$(cd "$(dirname "$0")" && pwd)
$d/run_godot.sh patch lee_rotor_new "test_lee_rotor.gd"
$d/run_godot.sh patch atmosphere_new "/test_atmosphere.gd"
