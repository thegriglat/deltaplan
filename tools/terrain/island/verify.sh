#!/bin/sh
# Детерминизм учебного острова: сборка во временную папку и побитное сравнение с data/locations/training_island
# и configs/locations/training_island.json. exit 0 — совпало.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
[ -x "$HERE/.venv/bin/python" ] || sh "$HERE/setup_env.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$HERE/.venv/bin/python" "$HERE/build_island.py" --out "$TMP/loc" --config "$TMP/cfg.json" >/dev/null
REF="$ROOT/data/locations/training_island"
rc=0
for f in "$REF"/* "$TMP"/loc/*; do
  n="$(basename "$f")"
  case "$n" in *.import) continue ;; esac   # импорт Godot — не данные места
  if ! cmp -s "$REF/$n" "$TMP/loc/$n"; then echo "РАЗНИЦА: $n"; rc=1; fi
done
cmp -s "$ROOT/configs/locations/training_island.json" "$TMP/cfg.json" || { echo "РАЗНИЦА: configs/locations/training_island.json"; rc=1; }
[ $rc -eq 0 ] && echo "совпало: $(ls "$REF" | grep -vc '\.import$') файлов + конфиг"
exit $rc
