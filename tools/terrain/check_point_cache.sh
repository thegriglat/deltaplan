#!/usr/bin/env bash
# OA-6: проверка «любая точка получает данные встроенного места, второй раз — из кеша без сети».
#   bash tools/terrain/check_point_cache.sh [lat lon]      (по умолчанию Альпы 47.05 11.0)
# Один постоянный XDG_DATA_HOME (build/point_cache_xdg) на оба прогона; кеш блоков user://terrain_cache
# между запусками проверки сохраняется (сеть вежливо), а собранное место перед прогоном стирается.
# 1) сборка с сетью; 2) тот же запуск в unshare -rn (нет сети) с --offline.
# Итог — строки key=value на экран и в build/point_cache.txt.
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/../.."
lat="${1:-47.05}"
lon="${2:-11.0}"
export XDG_DATA_HOME="$PWD/build/point_cache_xdg"
mkdir -p "$XDG_DATA_HOME" build
out=build/point_cache.txt
log_on=build/point_cache_online.log
log_off=build/point_cache_offline.log
run=(godot --headless --path . -s res://tools/terrain/build_location.gd)

# профиль в первый раз надо импортировать
[ -d .godot/imported ] || godot --headless --path . --import >/dev/null 2>&1

# стираем только собранные места, блоки (terrain_cache) оставляем
find "$XDG_DATA_HOME" -type d -name locations -prune -exec rm -rf {} + 2>/dev/null

t0=$(date +%s.%N)
timeout 3000 "${run[@]}" -- --lat "$lat" --lon "$lon" >"$log_on" 2>&1
rc_on=$?
online_s=$(LC_ALL=C printf '%.1f' "$(echo "$(date +%s.%N) - $t0" | bc)")

timeout 1200 unshare -rn "${run[@]}" -- --lat "$lat" --lon "$lon" --offline >"$log_off" 2>&1
rc_off=$?

field() { grep -m1 "^$2" "$1" | sed "s/^$2 *//"; }
key=$(field "$log_on" "ключ:")
dir=$(field "$log_on" "папка:")
on_net=$(field "$log_on" "net_requests:")
off_net=$(field "$log_off" "net_requests:")
missing=$(field "$log_on" "missing:")
off_missing=$(field "$log_off" "missing:")
size=$(field "$log_on" "размер папки:" | sed 's/ МБ//')
roads=$(python3 -I - "$dir/osm.json" <<'PY' 2>/dev/null || echo 0
import json, sys
try:
    print(len(json.load(open(sys.argv[1])).get("roads", [])))
except Exception:
    print(0)
PY
)
complete=false
if [ "$rc_on" = 0 ] && [ "$rc_off" = 0 ] && [ "${off_net:-1}" = 0 ] \
  && [ "$off_missing" = "$missing" ] \
  && python3 -I -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]+'/build.json')).get('complete') else 1)" "$dir" 2>/dev/null; then
  complete=true
fi
{
  echo "point=$lat,$lon"
  echo "key=$key"
  echo "online_seconds=$online_s"
  echo "online_net_requests=${on_net:-?}"
  echo "offline_net_requests=${off_net:-?}"
  echo "offline_complete=$complete"
  echo "missing=$missing"
  echo "osm_roads=$roads"
  echo "size_mb=${size:-?}"
  echo "exit_online=$rc_on"
  echo "exit_offline=$rc_off"
  echo "dir=$dir"
} | tee "$out"
