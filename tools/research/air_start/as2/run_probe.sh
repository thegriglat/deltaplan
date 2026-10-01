#!/usr/bin/env bash
# AS-2: прогон зонда (окно, GPU-замок). run_probe.sh <метка> [каталог_вывода]
# Переменные: AS2_CASES (место/старт:км/ч,…), AS2_SEEDS (по умолчанию 0,1500,3000).
set -uo pipefail
cd "$(dirname "$0")/../../../.."
tag=$1
out=${2:-$HOME/as2out}
mkdir -p "$out"
cp tools/research/air_start/as2/probe_test_as2probe.gd.txt tests/game/test_as2probe.gd
export AS2_OUT=$out AS2_TAG=$tag
export AS2_SEEDS=${AS2_SEEDS:-0,1500,3000}
export AS2_CASES=${AS2_CASES:-ongudai/kayancha_south:10.8,ongudai/kayancha_south:21.6,altai/sinyukha_west:10.8,altai/sinyukha_west:21.6,askarovo/biyagoda_west:10.8,askarovo/biyagoda_west:21.6,aushkul/aushtau_east:10.8,aushkul/aushtau_east:21.6}
flock /tmp/heat_ca_gpu.lock timeout 3600 tools/gpu_tests.sh --filter=as2probe > "$out/${tag}_run.log" 2>&1
rc=$?
rm -f tests/game/test_as2probe.gd tests/game/test_as2probe.gd.uid
echo "rc=$rc"
exit $rc
