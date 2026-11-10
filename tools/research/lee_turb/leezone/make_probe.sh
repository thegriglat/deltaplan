#!/usr/bin/env bash
# make_probe.sh <копия>: tests/atmosphere/probe_lee.gd = начало test_ridge_starts.gd (до первого теста) + probe_tail.gd.part
set -euo pipefail
d=$(cd "$(dirname "$0")" && pwd)
wt=$1
n=$(grep -n '^func test_ridge_no_climb_8kmh' "$wt/tests/atmosphere/test_ridge_starts.gd" | cut -d: -f1)
head -n $((n-1)) "$wt/tests/atmosphere/test_ridge_starts.gd" > "$wt/tests/atmosphere/probe_lee.gd"
cat "$d/probe_tail.gd.part" >> "$wt/tests/atmosphere/probe_lee.gd"
