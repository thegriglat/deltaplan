#!/bin/bash
# Все места/слои/уровни -> results/godot_*.jsonl ; запускать из этой папки
cd "$(dirname "$0")"; mkdir -p results; export XDG_DATA_HOME=$(mktemp -d)
for P in altai ongudai aushkul askarovo; do for L in detail far; do
 for Q in 32 8; do godot --headless --path godot_bench --script bench.gd -- $P $L $Q 2>&1 | grep '^RESULT' | sed 's/^RESULT //' >> results/godot_l3.jsonl; done
 for Z in 19 22; do godot --headless --path gb$Z --script bench.gd -- $P $L 32 2>&1 | grep '^RESULT' | sed 's/^RESULT //' >> results/godot_l$Z.jsonl; done
done; done
