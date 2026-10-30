#!/usr/bin/env bash
# Все варианты опыта RW-6z подряд; chunk1000 - с временной правкой util.rs, потом откат.
set -euo pipefail
cd "$(dirname "$0")/../../.."
D=tools/research/rust_wind_t1_stability
for v in base pert_u10 pert_t; do $D/run_variant.sh $v; done
git apply $D/chunk1000.patch
trap 'git apply -R $D/chunk1000.patch' EXIT
$D/run_variant.sh chunk1000
