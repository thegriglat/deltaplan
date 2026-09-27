#!/bin/bash
# Скриншоты всех моделей для docs/models/screenshots/<модель>/ (параллельно, ~2 мин).
# Использование: tools/blender/render_all.sh [out_dir] [виды для крыльев]
cd "$(dirname "$0")/../.."
OUT=${1:-docs/models/screenshots}
VIEWS=${2:-bottom,front,side,iso45,cockpit}
for k in glider_training glider_kingpost glider_sport pilot instrument vario_90s; do
  V=$VIEWS
  [[ $k == glider_* ]] || V=bottom,front,side,iso45
  xvfb-run -a blender --background --python tools/blender/render_views.py -- "$k" "$OUT/$k" "$V" \
    > "/tmp/render_$k.log" 2>&1 &
done
wait
grep -h -E "Error|Traceback" /tmp/render_*.log
uv run -q --with pillow python tools/blender/compress_png.py "$OUT"
ls -la "$OUT"/*/
