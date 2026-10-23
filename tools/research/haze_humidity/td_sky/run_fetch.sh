#!/bin/bash
# Скачивание 2011-2020 (ARCO 1°, блоки по 8 суток, готовые блоки пропускаются), по процессу на год, 5 параллельно, повтор при падении.
cd "$(dirname "$0")"
PY=~/data/haze_humidity/venv/bin/python
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
one() { for a in 1 2 3 4 5 6 7 8; do $PY fetch_tcc.py $1 $1 && return 0; sleep 10; done; }
export -f one; export PY
seq 2020 -1 2011 | xargs -P 3 -I{} bash -c 'one {}'
