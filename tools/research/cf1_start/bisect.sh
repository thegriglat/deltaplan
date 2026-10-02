#!/usr/bin/env bash
# CF-1: зонд старта по умолчанию на нескольких версиях (headless; GPU=1 — ещё и с окном).
set -u
SP=/home/greg/projects/.tmp/claude-1000/-home-greg-deltaplan/55d419f6-4839-418d-8f65-ded00754411a/scratchpad
OUT=$HOME/cf1out
mkdir -p "$OUT"
cd /home/greg/deltaplan-control-fix-cf1
for c in "$@"; do
	if ls "$OUT/${c}_idle.csv" >/dev/null 2>&1 && [ "${GPU:-0}" = 0 ]; then echo "skip $c"; continue; fi
	wt=$HOME/deltaplan-cf1-bisect-$c
	[ -d "$wt" ] || git worktree add --detach "$wt" "$c" >/dev/null 2>&1
	cp "$SP/test_cf1probe.gd" "$wt/tests/game/test_cf1probe.gd"
	if [ ! -f "$wt/.godot/imported_done" ]; then
		XDG_DATA_HOME=$(mktemp -d) timeout 900 godot --headless --path "$wt" --import >"$OUT/${c}_import.log" 2>&1
		touch "$wt/.godot/imported_done"
	fi
	if [ "${GPU:-0}" = 1 ]; then
		(cd "$wt" && cp project.godot /tmp/cf1_pg_$c && CF1_OUT=$OUT CF1_TAG=${c}gpu XDG_DATA_HOME=$(mktemp -d) timeout 1500 godot --path . --audio-driver Dummy --resolution 320x240 res://tests/run_tests.tscn -- --gpu --filter=cf1probe >"$OUT/${c}gpu_run.log" 2>&1; cp /tmp/cf1_pg_$c project.godot)
	else
		CF1_OUT=$OUT CF1_TAG=$c XDG_DATA_HOME=$(mktemp -d) timeout 900 godot --headless --path "$wt" res://tests/run_tests.tscn -- --filter=cf1probe >"$OUT/${c}_run.log" 2>&1
	fi
	echo "done $c $(date +%T)"
done
