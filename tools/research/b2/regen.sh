#!/usr/bin/env bash
# Б2: пересчёт фикстур GPU-тестов на параметрах C2 v4 (α по устойчивости, λ/h 0,0158) теми же генераторами.
#   tools/research/b2/regen.sh   (CuPy, под замком GPU) → tests/atmosphere/fixtures/air_model/{picard,window,ref}/
set -uo pipefail
cd "$(dirname "$0")/../air3d"
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
for g in picard_gpu_refs.py window_gpu_refs.py fixtures.py; do
	echo "== $g $(date +%T)"
	flock /tmp/heat_ca_gpu.lock "$PY" "$g"
	echo "== $g: $? $(date +%T)"
done
