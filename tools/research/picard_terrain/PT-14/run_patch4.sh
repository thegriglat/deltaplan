#!/usr/bin/env bash
# run_patch4.sh: те же правленные тесты на «до» и «PT-9» (копии с применённым patch_tests_lee.patch)
d=$(cd "$(dirname "$0")" && pwd)
for s in f44c66b4a 4316db7e0; do
$d/run_godot.sh $s lee_rotor_new "test_lee_rotor.gd"
$d/run_godot.sh $s atmosphere_new "/test_atmosphere.gd"
done
