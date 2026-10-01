#!/bin/bash
# Рендеры крыльев в iso45 для сайта (docs/models/screenshots/glider_<id>/iso45.jpg).
# Использование: tools/blender/render_wings_site.sh [wing_ids...]
#   По умолчанию обрабатывает все крылья из configs/wings/*.json.
#   Если передать ID аргументами, обрабатывает только их (например: ww_t2c slavutich_ut).
# Выход: временные PNG во ${TMPDIR:-/tmp}/render_wings_site/,
#   затем вызывает wings_site_jpg.py для преобразования в JPEG.
set -e
cd "$(dirname "$0")/../.."

TMPDIR=${TMPDIR:-/tmp}
RENDER_DIR="$TMPDIR/render_wings_site"
mkdir -p "$RENDER_DIR"

# Получить список ID крыльев (все или переданные аргументами)
if [ $# -gt 0 ]; then
  WING_IDS="$@"
else
  WING_IDS=$(for f in configs/wings/*.json; do b=${f##*/}; echo "${b%.json}"; done)
fi

R="xvfb-run -a blender --background --python tools/blender/render_views.py --"

# Рендер iso45 для каждого крыла, 4 параллельно
COUNT=0
for wing_id in $WING_IDS; do
  wing_dir="$RENDER_DIR/$wing_id"
  mkdir -p "$wing_dir"
  $R "glider_$wing_id" "$wing_dir" iso45 > "$RENDER_DIR/${wing_id}.log" 2>&1 &
  COUNT=$((COUNT + 1))
  if [ $((COUNT % 4)) -eq 0 ]; then
    wait
  fi
done
wait

# Проверить ошибки рендера
if grep -h -E "Error|Traceback" "$RENDER_DIR"/*.log 2>/dev/null; then
  echo "Ошибки рендера — см. $RENDER_DIR/*.log"
  exit 1
fi

echo "Рендеры готовы в $RENDER_DIR, запуск преобразования PNG→JPEG..."
uv run -q --with pillow python tools/blender/wings_site_jpg.py "$RENDER_DIR" "docs/models/screenshots"
