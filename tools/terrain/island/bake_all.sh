#!/bin/sh
# Запекание полей ветра четырёх стартов учебного острова (TI-9, контракт TI-К3 v2) в
# data/locations/training_island/air/<старт>.json + .bin.
#   bake_all.sh           — запечь все старты (GPU, окно; по умолчанию, под замком gpu: .dpcli/dpcli lock gpu bake -- …)
#   bake_all.sh --check   — проверить свежесть всех файлов (без GPU); exit 1, если хоть один устарел или файла нет
# Профиль Godot: XDG_DATA_HOME берётся из окружения.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
ID=training_island
SITES="ridge_west thermal_plain landing_hill lee_bowl"
cd "$ROOT" || exit 2
if [ "${1:-}" = "--check" ]; then
  rc=0
  for s in $SITES; do
    [ -f "data/locations/$ID/air/$s.json" ] && [ -f "data/locations/$ID/air/$s.bin" ] || { echo "нет файла: $s"; rc=1; continue; }
    godot --headless --path . res://tools/terrain/bake_air.tscn -- --check --id=$ID --site=$s || rc=1
  done
  exit $rc
fi
rc=0
for s in $SITES; do
  DISPLAY="${DISPLAY:-:0}" godot --path . --audio-driver Dummy --disable-vsync res://tools/terrain/bake_air.tscn -- --id=$ID --site=$s || rc=1
done
git checkout -- project.godot 2>/dev/null || true
exit $rc
