#!/usr/bin/env bash
# Б2: цена на сетках игры — GPU-тесты test_air_ и bench Пикара 400/200 м (QUICK и полный).
#   tools/research/b2/bench.sh <метка> [корень копии]   → tools/research/b2/out/bench/<метка>_*.log
# Как tools/gpu_tests.sh (окно 320×240, временный профиль, project.godot возвращается), но с
# --disable-vsync --max-fps 60: при погашенном мониторе (DPMS) X11/NVIDIA тормозит vsync до ~1 кадра/с,
# опрос задач решателя идёт раз в кадр — без этого стена и таймауты 60 с бессмысленны; 60 кадров/с —
# как у включённого монитора 60 Гц. «До» — копия на базовом коммите (git worktree), «после» — эта копия.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tag="${1:?метка}"
root="${2:-$here/../../..}"
out="$here/out/bench"
mkdir -p "$out"
cd "$root"
gt() {
	local profile
	profile="$(mktemp -d)"
	cp project.godot "$profile/project.godot.bak"
	XDG_DATA_HOME="$profile" flock /tmp/heat_ca_gpu.lock godot --path . --audio-driver Dummy --resolution 320x240 \
		--disable-vsync --max-fps 60 res://tests/run_tests.tscn -- --gpu "$@"
	local st=$?
	cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot
	rm -rf "$profile"
	return $st
}
gt --filter=test_air_ > "$out/${tag}_gpu_tests.log" 2>&1
echo "gpu_tests: $? $(grep -a 'тестов,' "$out/${tag}_gpu_tests.log" | tail -1)"
for dx in 400 200; do
	for q in 1 0; do
		AIR_PICARD_BENCH=1 AIR_PICARD_BENCH_DX=$dx AIR_PICARD_BENCH_QUICK=$q gt --filter=test_air_picard_bench \
			> "$out/${tag}_bench${dx}_q${q}.log" 2>&1
		echo "bench $dx q$q: $?"
	done
done
