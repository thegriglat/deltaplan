#!/usr/bin/env bash
# Стенд cliff-look (CL-К1 v1, docs/contracts/cliff-look.md): кадры всех ракурсов tools/shots/cliff_look_views.json.
#   tools/shots/cliff_look_shots.sh <before|after|метка> [--views=путь] [--diag|--diag-only] [--places=tag,…] [--preset=high]
# Кадры — /home/greg/deltaplan/build/screenshots/cliff-look/<метка>_<tag>_<view>.jpg (JPEG q88, 1920×1080).
# --diag — ещё диагноз членов раскраски скал (кадры diag_<tag>_<view>_<член>.jpg там же, сырые RGB8 и маски —
#   build/cliff_look_raw/<метка>/, числа — python3 -I tools/research/cliff_look/diag_metrics.py build/cliff_look_raw/<метка>).
# Профиль Godot — общий кеш мест копии build/cliff_look_xdg (не профиль копии; первый прогон собирает места из сети),
# пресет графики — --preset (по умолчанию high). Окну нужен дисплей (DISPLAY=:0), без GPU-замка; каждый запуск под timeout.
# Игра с окном переписывает project.godot — после запуска возвращаем.
set -uo pipefail
cd "$(dirname "$0")/../.."
label="${1:?метка: before|after|…}"
shift
views="tools/shots/cliff_look_views.json"
diag=0
places=""
preset="high"
for a in "$@"; do
  case "$a" in
    --views=*) views="${a#--views=}" ;;
    --diag) diag=1 ;;
    --diag-only) diag=2 ;;
    --places=*) places="${a#--places=}" ;;
    --preset=*) preset="${a#--preset=}" ;;
    *) echo "неизвестный аргумент $a" >&2; exit 2 ;;
  esac
done
out="/home/greg/deltaplan/build/screenshots/cliff-look"
raw="$PWD/build/cliff_look_raw/$label"
mkdir -p "$out" "$raw"
export DISPLAY="${DISPLAY:-:0}" XDG_DATA_HOME="$PWD/build/cliff_look_xdg"
mkdir -p "$XDG_DATA_HOME"
[[ -z "$places" ]] && places=$(python3 -I -c "import json,sys;print(','.join(p['tag'] for p in json.load(open(sys.argv[1]))['places']))" "$views")
godot --headless --path . res://tools/bench/set_preset.tscn -- --preset="$preset" 2>&1 | grep -E "set_preset" || true
fail=0
run() {  # run <tag> <mode>
  timeout 1800 godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 res://tools/shots/cliff_look_shot.tscn -- \
    "--views=$views" "--place=$1" "--mode=$2" "--label=$label" "--out=$out" "--raw=$raw" 2>&1 \
    | grep -E "^cliff_look_shot:|SCRIPT ERROR|^ERROR" | grep -v "диагноз " || true
}
for tag in ${places//,/ }; do
  echo "== $tag"
  [[ $diag -lt 2 ]] && run "$tag" shots
  [[ $diag -ge 1 ]] && run "$tag" diag
  n=$(ls "$out/${label}_${tag}_"*.jpg 2>/dev/null | wc -l)
  [[ $n -ge 2 ]] || { echo "ОШИБКА: $tag — кадров $n" >&2; fail=1; }
done
git checkout -- project.godot 2>/dev/null
ls "$out/${label}_"*.jpg 2>/dev/null | wc -l | sed 's/^/кадров /'
exit $fail
