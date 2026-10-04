#!/bin/sh
# Окружение корпуса air-synth: .venv рядом (не коммитить). Идемпотентно.
set -e
cd "$(dirname "$0")"
[ -x .venv/bin/python ] || uv venv -q --python 3.12 .venv
uv pip install -q --python .venv/bin/python -r requirements.in
