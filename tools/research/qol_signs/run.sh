#!/usr/bin/env bash
# QL-5/QL-8: весь план одним прогоном. Использование (из корня копии):
#   dp job --lock gpu start ql5 3000 tools/research/qol_signs/run.sh
# GPU-часть (окно, поле «фазы + Пикар») → out/gpu_<место>_<час>.json,
# затем headless (аналитика) → out/ana_<место>_<час>.json; итог — summarize.py.
set -uo pipefail
cd "$(dirname "$0")/../../.."
OUT=${OUT:-tools/research/qol_signs/out_ql8}  # QL-5 лежит в out/ (до правок), повтор QL-8 — в out_ql8/
mkdir -p "$OUT"
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile"' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
for loc in ongudai altai askarovo aushkul; do
  for h in 13 15; do
    echo "== GPU $loc $h"
    XDG_DATA_HOME="$profile" godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
      res://tools/research/qol_signs/signs_probe.tscn -- "$loc" "$h" "$OUT/gpu_${loc}_${h}.json" 600 2>&1 | grep -E "air_model|QL5|ERROR|SCRIPT" 
  done
done
for loc in ongudai altai askarovo aushkul; do
  for h in 13 15; do
    echo "== ANA $loc $h"
    XDG_DATA_HOME="$profile" godot --headless --path . \
      res://tools/research/qol_signs/signs_probe.tscn -- "$loc" "$h" "$OUT/ana_${loc}_${h}.json" 600 2>&1 | grep -E "air_model|QL5|ERROR|SCRIPT"
  done
done
python3 tools/research/qol_signs/summarize.py
