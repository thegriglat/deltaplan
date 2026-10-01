#!/bin/sh
# А1.3 (ревью), вторая пачка: варианты диагноза 200 м (по 400 итераций), контроль на air.py до А1,
# затем GPU-тесты test_air_* и bench 400 м. GPU под замком. Запуск (из этого каталога):
#   /home/greg/deltaplan/tools/job.sh start a1rev2 5400 sh run_all2.sh
# AIR3D_OLD — каталог с air.py от feature/air-model и ссылками на остальные модули air3d (контроль «до»).
cd "$(dirname "$0")"
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
L="flock /tmp/heat_ca_gpu.lock"
for v in ${DIAG:-prt1 nocpl oldsth dtau600 nolocal sweeps8}; do
  $L $PY diag200.py $v ${DIAG_ITERS:-400} > out/diag200_$v.log 2>&1 || echo "diag $v failed"
done
if [ -n "$AIR3D_OLD" ]; then
  AIR3D_DIR=$AIR3D_OLD $L $PY diag200.py base32 ${DIAG_ITERS:-400} > out/diag200_old_base32.log 2>&1 || echo "diag old failed"
fi
ROOT=$(cd ../../../.. && pwd)
( cd "$ROOT" && $L tools/gpu_tests.sh --filter=test_air_ > tools/research/a1/review/out/gpu_tests.log 2>&1; echo "exit $?" >> tools/research/a1/review/out/gpu_tests.log )
( cd "$ROOT" && AIR_PICARD_BENCH=1 AIR_PICARD_BENCH_DX=400 $L tools/gpu_tests.sh --filter=test_air_picard_bench > tools/research/a1/review/out/bench400.log 2>&1; echo "exit $?" >> tools/research/a1/review/out/bench400.log )
echo done
