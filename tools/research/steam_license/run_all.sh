#!/usr/bin/env bash
# pck-сверка и экспорт: подряд (оба используют .godot/ копии)
set -euo pipefail
cd "$(dirname "$0")/../../.."
tools/research/steam_license/run_pack.sh
tools/research/steam_license/run_export.sh
