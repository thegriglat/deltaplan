#!/bin/bash
# заход 2: v5 (γ = 1) и справочно v5 с γ = 0, один скрипт под блокировкой cpu
cd "$(dirname "$0")/.." || exit 1
.venv/bin/python p3/pod.py --enc v5 --workers 4 && .venv/bin/python p3/pod.py --enc v5 --gamma0 --workers 4
