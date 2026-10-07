#!/usr/bin/env bash
# QL-9: замер признаков ThermalSigns «после» тем же стендом, что QL-5 (4 места × 13:00/15:00 × 2 точки, 600 с мира).
#   dp job --lock gpu start ql9 3300 tools/research/qol_signs/run9.sh
# GPU-поле («фазы + Пикар») → out/s9_gpu_<место>_<час>.json; затем summarize9.py дописывает раздел qol9
# в summary_numbers.json (чужие разделы не трогает).
set -uo pipefail
cd "$(dirname "$0")/../../.."
OUT=tools/research/qol_signs/out
profile="$(mktemp -d)"
cp project.godot "$profile/project.godot.bak"
trap 'cmp -s project.godot "$profile/project.godot.bak" || cp "$profile/project.godot.bak" project.godot; rm -rf "$profile"' EXIT
XDG_DATA_HOME="$profile" godot --headless --path . --import >/dev/null 2>&1 || true
for loc in ongudai altai askarovo aushkul; do
  for h in 13 15; do
    echo "== GPU $loc $h"
    XDG_DATA_HOME="$profile" godot --path . --audio-driver Dummy --resolution 320x240 --disable-vsync \
      res://tools/research/qol_signs/signs9_probe.tscn -- "$loc" "$h" "$OUT/s9_gpu_${loc}_${h}.json" 600 2>&1 | grep -E "air_model|QL9|ERROR|SCRIPT"
  done
done
python3 tools/research/qol_signs/summarize9.py
