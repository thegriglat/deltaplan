#!/bin/sh
# Запекание/проверка полей ветра всех встроенных мест (VI-К3, формат поля — TI-К3 v3).
# Места и старты — из configs/locations/*.json: "bundled": true, старты с ключом weather.
#   bake_all.sh [--id <место>]           — запечь (GPU, окно; под замком: .dpcli/dpcli lock gpu bake -- …)
#   bake_all.sh --check [--id <место>]   — проверить свежесть (без GPU); 0 — свежие, 1 — устарели/нет файла, 2 — ошибка запуска
# Профиль Godot: XDG_DATA_HOME берётся из окружения.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
CHECK=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --id) shift; ONLY="${1:-}"; [ -n "$ONLY" ] || { echo "--id: нужно имя места"; exit 2; } ;;
    --id=*) ONLY="${1#--id=}" ;;
    *) echo "неизвестный аргумент: $1"; exit 2 ;;
  esac
  shift
done
LIST="$(python3 - "$ONLY" <<'PY'
import glob, json, sys
only = sys.argv[1]
found = False
for p in sorted(glob.glob("configs/locations/*.json")):
    d = json.load(open(p, encoding="utf-8"))
    if not d.get("bundled"):
        continue
    pid = p.split("/")[-1][:-5]
    if only and pid != only:
        continue
    found = True
    for s in d.get("start_sites", []):
        if "weather" in s:
            print(pid, s.get("id", ""))
if only and not found:
    print("ERR_UNKNOWN")
PY
)" || exit 2
if [ "$LIST" = "ERR_UNKNOWN" ]; then echo "неизвестное встроенное место: $ONLY"; exit 2; fi
if [ -z "$LIST" ]; then echo "нет стартов с weather${ONLY:+ у места $ONLY}"; exit 2; fi
rc=0
while read -r id site; do
  [ -n "$site" ] || { echo "$id: старт без id"; rc=2; continue; }
  if [ "$CHECK" = 1 ]; then
    if [ ! -f "data/locations/$id/air/$site.json" ] || [ ! -f "data/locations/$id/air/$site.bin" ]; then
      echo "$id/$site: нет файла"; [ $rc = 2 ] || rc=1; continue
    fi
    if godot --headless --path . res://tools/terrain/bake_air.tscn -- --check --id="$id" --site="$site" >/dev/null 2>&1; then
      echo "$id/$site: ok"
    else
      echo "$id/$site: устарело"; [ $rc = 2 ] || rc=1
    fi
  else
    DISPLAY="${DISPLAY:-:0}" godot --path . --audio-driver Dummy --disable-vsync res://tools/terrain/bake_air.tscn -- --id="$id" --site="$site" || rc=1
    echo "$id/$site: запечено"
  fi
done <<EOT
$LIST
EOT
git checkout -- project.godot 2>/dev/null || true
exit $rc
