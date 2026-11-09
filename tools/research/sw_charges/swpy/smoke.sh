#!/usr/bin/env bash
# Дымовой прогон: случай ridge (1D, nx 256) -> swc run -> проверка контракта SW1–SW3.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$root/py" -m swpy case ideal --name smoke --shape ridge --H 25 --s 0.2 --dim 1 --nx 256 --dx 50 --U0 2.1 \
  --sponge-width 3000 --t-end 3000 --out "$tmp" >/dev/null
"$root/py" -m swpy run "$tmp/smoke.json" --out "$tmp" -q >/dev/null
python3 "$root/contract/check_contract.py" "$tmp"
