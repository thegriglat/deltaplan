#!/usr/bin/env bash
# Проверка воспроизводимости: сборка из сети во временном профиле, сравнение высот и классов с data/locations/volcano_island (numpy).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
P="$(mktemp -d)"; cp "$ROOT/project.godot" "$P/pg.bak"
(cd "$ROOT" && XDG_DATA_HOME="$P" godot --headless --path . -s res://tools/terrain/build_location.gd -- --lat -27.10 --lon -109.35) > "$P/log" 2>&1 || true
cmp -s "$ROOT/project.godot" "$P/pg.bak" || cp "$P/pg.bak" "$ROOT/project.godot"
tail -8 "$P/log"
"$HERE/.venv/bin/python" "$HERE/compare.py" "$P/Deltaplan/locations/pt_-27.100_-109.350" "$ROOT/data/locations/volcano_island"
