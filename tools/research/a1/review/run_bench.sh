#!/bin/sh
# А1.3, замеры на свободном GPU (после остановки llama-server): цена итерации до/после, bench 200 м целиком
# (таймаут/segfault), повтор эталона 200 м, 3 м/с с нагревом на 3000 итераций.
#   BEFORE=<worktree feature/air-model с импортом> /home/greg/deltaplan/tools/job.sh start a1bench 5400 sh run_bench.sh
cd "$(dirname "$0")"
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
L="flock /tmp/heat_ca_gpu.lock"
ROOT=$(cd ../../../.. && pwd)
O=$PWD/out
bench() {  # bench <корень> <dx> <quick 0/1> <имя лога>
  ( cd "$1" && AIR_PICARD_BENCH=1 AIR_PICARD_BENCH_DX=$2 AIR_PICARD_BENCH_QUICK=$3 $L tools/gpu_tests.sh --filter=test_air_picard_bench > "$O/$4.log" 2>&1; echo "exit $?" >> "$O/$4.log" )
}
bench "$ROOT" 400 1 bench_after400_quick
bench "$ROOT" 200 1 bench_after200_quick
if [ -n "$BEFORE" ]; then
  bench "$BEFORE" 400 1 bench_before400_quick
  bench "$BEFORE" 200 1 bench_before200_quick
fi
bench "$ROOT" 200 0 bench_after200_full
DIAG_TAG=_3000 $L $PY diag200.py base32 3000 > out/diag200_base32_3000.log 2>&1 || echo "diag failed"
echo done
