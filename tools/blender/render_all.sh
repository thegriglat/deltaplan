#!/bin/bash
# Скриншоты всех моделей для docs/models/screenshots/<модель>/ (параллельно, ~3 мин).
# Использование: tools/blender/render_all.sh [out_dir] [виды для крыльев]
cd "$(dirname "$0")/../.."
OUT=${1:-docs/models/screenshots}
VIEWS=${2:-bottom,front,side,iso45,cockpit}
R="xvfb-run -a blender --background --python tools/blender/render_views.py --"
for k in glider_training glider_kingpost glider_sport pilot instrument vario_90s; do
  V=$VIEWS
  [[ $k == glider_* ]] || V=bottom,front,side,iso45
  $R "$k" "$OUT/$k" "$V" > "/tmp/render_$k.log" 2>&1 &
done
wait
# позы пилота (с учебным крылом, вид сбоку 3/4) и вид из глаз вниз на старте
T=/tmp/render_poses
mkdir -p $T
for p in stand:1 walk:7 run:5 run_air:12 climb_in:20 prone:1 climb_out:18 flare:1; do
  WITH_PILOT=1 POSE=${p%%:*} POSE_FRAME=${p##*:} EXTRA_CAMS="c1:75:5:0.75:35" \
    $R glider_training "$T/${p%%:*}" c1 > "/tmp/render_pose_${p%%:*}.log" 2>&1 &
done
$R glider_training "$T/pov" pov_down > /tmp/render_pov.log 2>&1 &
wait
for p in stand walk run run_air climb_in prone climb_out flare; do
  cp "$T/$p/c1.png" "$OUT/pilot/pose_$p.png"
done
cp "$T/pov/pov_down.png" "$OUT/pilot/pov_down.png"
grep -h -E "Error|Traceback" /tmp/render_*.log
uv run -q --with pillow python tools/blender/compress_png.py "$OUT"
