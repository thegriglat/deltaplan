#!/bin/bash
# PD-35: пересчёт эталона прототипа (полный + земля)
cd "$(dirname "$0")/../../../.." || exit 1
PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
systemd-run --user --scope -p MemoryMax=12G -q $PY tools/research/pendulum/export_reference.py --jobs 6 && \
systemd-run --user --scope -p MemoryMax=12G -q $PY tools/research/pendulum/export_reference.py --jobs 6 --ground
