#!/usr/bin/env bash
# Трава: кадры из фиксированных поз (GR-25) — для сравнения вариантов (до/после, off/blades/shell/angle,
# формы карточек) попиксельно по рельефу. Без автопилота: на старте пилот стоит (поза — точка старта
# и --look), в воздухе (--air-start) — прямой полёт на триме, кадр через 0,1 с после старта (смещение
# ≤ 1 м); --autostart берёт сид мира из configs/atmosphere.json — раскладка ветра та же.
# tools/shots/grass_look_fixed.sh <выход> [виды…]   (виды по умолчанию: 1 4 9 10 11)
#   1  1_cockpit            старт, кабина, взгляд вниз 15°
#   4  4_low_meadow         600 м от старта по курсу, 15 м над рельефом, камера сзади
#   9  9_slope_ground       старт, кабина, взгляд вбок 90° вдоль склона, вниз 3°
#   10 10_meadow_side       600 м от старта, 2 м над лугом, кабина, взгляд вбок 90°, вниз 3° (карточки 8–40 м)
#   11 11_meadow_side_down  то же, вниз 10°
#   e1 e1_rock_edge         150 м от старта по курсу, 4 м над рельефом, вперёд-вниз 12°: пятно породы
#                           на 8–30 м, вокруг луг — стык порода/луг вблизи и на средней дистанции
#   e2 e2_rock_near         то же, вниз 25°: порода вблизи
#   e3 e3_rock_edge_mid     80 м от старта, 4 м, вниз 12°: луг вблизи, пятно породы справа на ~30 м
#   t30 top30               600 м от старта, 30 м над травяным склоном, кабина, вперёд-вниз 35°
#   t60 top60               то же с 60 м
#   e4 e4_rock_mid          150 м от старта, 10 м над рельефом, вниз 30°: пятно породы сверху
# Переменные окружения игры (DP_GRASS_MID, DP_GRASS_CARDS, DP_GRASS_DENSITY) передаются как есть.
# Окну нужен дисплей (DISPLAY=:0), --fullscreen; запуск — под замком GPU (иначе окна делят экран).
set -uo pipefail
cd "$(dirname "$0")/../.."

out="${1:?выходной каталог}"
shift
views=("$@")
[[ ${#views[@]} -eq 0 ]] && views=(1 4 9 10 11)
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$PWD")}"
mkdir -p "$XDG_DATA_HOME"

for v in "${views[@]}"; do
  case $v in
    1) f=1_cockpit; a=(--camera=cockpit --look=0,-15 --time=1) ;;
    4) f=4_low_meadow; a=(--air-start=600,15 --camera=chase --time=0.1) ;;
    9) f=9_slope_ground; a=(--camera=cockpit --look=90,-3 --time=1) ;;
    10) f=10_meadow_side; a=(--air-start=600,2 --camera=cockpit --look=90,-3 --time=0.1) ;;
    11) f=11_meadow_side_down; a=(--air-start=600,2 --camera=cockpit --look=90,-10 --time=0.1) ;;
    e1) f=e1_rock_edge; a=(--air-start=150,4 --camera=cockpit --look=0,-12 --time=0.1) ;;
    e2) f=e2_rock_near; a=(--air-start=150,4 --camera=cockpit --look=0,-25 --time=0.1) ;;
    e3) f=e3_rock_edge_mid; a=(--air-start=80,4 --camera=cockpit --look=0,-12 --time=0.1) ;;
    e4) f=e4_rock_mid; a=(--air-start=150,10 --camera=cockpit --look=0,-30 --time=0.1) ;;
    t30) f=top30; a=(--air-start=600,30 --camera=cockpit --look=0,-35 --time=0.1) ;;
    t60) f=top60; a=(--air-start=600,60 --camera=cockpit --look=0,-35 --time=0.1) ;;
    *) echo "WARN: неизвестный вид $v" >&2; continue ;;
  esac
  rm -f "$out/$f.jpg"
  for try in 1 2; do
    timeout 150 godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
      -- --autostart --location=ongudai --wind=3 "${a[@]}" "--screenshot=$out/$f.jpg" 2>&1 \
      | grep -E "^screenshot:|SCRIPT ERROR" | head -3
    [[ -s "$out/$f.jpg" ]] && break
  done
  [[ -s "$out/$f.jpg" ]] || echo "WARN: нет кадра $out/$f.jpg" >&2
done
echo "grass_look_fixed.sh: кадры в $out"
