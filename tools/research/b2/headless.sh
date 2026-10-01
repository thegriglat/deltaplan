#!/usr/bin/env bash
# Б2: все headless-тесты по папкам tests/ (до 8 процессов параллельно), логи в out/headless/<метка>_<папка>.log.
#   tools/research/b2/headless.sh after
set -uo pipefail
cd "$(dirname "$0")/../../.."
tag="${1:?метка}"
out=tools/research/b2/out/headless
mkdir -p "$out"
run() {
	XDG_DATA_HOME="$(mktemp -d)" godot --headless --audio-driver Dummy --path . res://tests/run_tests.tscn -- "--filter=/$1/" \
		> "$out/${tag}_$1.log" 2>&1
	echo "$1: $? $(grep -a 'тестов,' "$out/${tag}_$1.log" | tail -1)"
}
dirs=(atmosphere audio contracts core flight game instruments net stability tasks terrain ui vegetation world world_objects)
i=0
for d in "${dirs[@]}"; do
	run "$d" &
	i=$((i + 1))
	if (( i % 8 == 0 )); then wait; fi
done
wait
git checkout -- project.godot 2>/dev/null || true
