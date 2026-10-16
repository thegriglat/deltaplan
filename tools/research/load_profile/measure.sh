#!/bin/bash
# measure.sh <тег> <ong|pt> <n> [--air-cache=keep|clear|off]
# n тёплых запусков зонда загрузки подряд в профиле ~/.cache/dp-xdg/loadprof-<место>. Код игры не размечается:
# только зонд probe.gd (копируется в tools/lp_tmp/ — tools/research под .gdignore — и удаляется после).
# Логи: logs/<тег>_<место>_<i>.log; сводка — measure.py <тег> → <тег>.json (контракт FL-К3 v1).
# --air-cache: clear — удалить air_cache профиля перед каждым запуском (miss); keep — не трогать (hit, если запись есть);
#              off — ничего не делать, кеша нет (air_cache=none). По умолчанию off.
# Профиль не создан/пуст (нет кеша мест) — первый запуск помечается cold и в медианы не входит.
# Запускать под замком: .dpcli/dpcli job --lock gpu start <имя> <таймаут> tools/research/load_profile/measure.sh …
set -u
tag=${1:?тег}; pl=${2:?ong|pt}; n=${3:?число запусков}; mode=off
for a in "${@:4}"; do
  case $a in --air-cache=keep|--air-cache=clear|--air-cache=off) mode=${a#--air-cache=} ;; *) echo "неизвестный аргумент $a" >&2; exit 64 ;; esac
done
case $pl in
  ong) place=--location=ongudai ;;
  pt) place=--latlon=-27.7176,-48.7799 ;;
  *) echo "место: ong|pt" >&2; exit 64 ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
cd "$root"
L=$here/logs; mkdir -p "$L"
X=$HOME/.cache/dp-xdg/loadprof-$pl
mkdir -p "$X"
cold_first=0
[ -z "$(ls -A "$X" 2>/dev/null)" ] && cold_first=1
# импорт проекта (class cache) при необходимости — в профиле копии
[ -d "$root/.godot" ] || XDG_DATA_HOME=$HOME/.cache/dp-xdg/$(basename "$root") godot --headless --path . --import >/dev/null 2>&1
mkdir -p tools/lp_tmp
cp "$here/probe.gd" "$here/probe.tscn" tools/lp_tmp/
trap 'rm -rf "$root/tools/lp_tmp"' EXIT
for i in $(seq 1 "$n"); do
  f=$L/${tag}_${pl}_$i.log
  ac=none
  shopt -s nullglob
  dirs=("$X/Deltaplan/air_cache")  # проект: use_custom_user_dir, имя Deltaplan
  shopt -u nullglob
  if [ "$mode" = clear ]; then rm -rf "${dirs[@]}"; ac=miss
  elif [ "$mode" = keep ]; then
    ac=miss; for d in "${dirs[@]}"; do [ -n "$(ls -A "$d" 2>/dev/null)" ] && ac=hit; done
  fi
  { echo "uptime: $(uptime)"; echo "air_cache: $ac"; echo "commit: $(git rev-parse --short HEAD)"
    [ "$i" = 1 ] && [ "$cold_first" = 1 ] && echo "cold: 1"; } > "$f"
  XDG_DATA_HOME=$X timeout 900 godot --path . --audio-driver Dummy --resolution 1280x720 \
    res://tools/lp_tmp/probe.tscn -- $place --timeout=800 --no-shots >> "$f" 2>&1
  echo "exit=$?" >> "$f"
  echo "uptime_end: $(uptime)" >> "$f"
done
python3 -I "$here/measure.py" "$tag"
