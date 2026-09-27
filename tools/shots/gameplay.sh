#!/usr/bin/env bash
# Геймплей свободного полёта (карточка docs/plan/game/03-geimplej-svobodnogo.md): по кадру на камеру —
# кабина (угла нет), сзади и свободная (прибор в углу). Чек-лист — docs/screenshots/gameplay/README.md.
# tools/shots/gameplay.sh [выход]   (по умолчанию docs/screenshots/gameplay)
# Онгудай, старт по умолчанию, синтетический пилот --autopilot, 20 с симуляции (пилот лёг, 30–50 м над склоном).
# Окну нужен настоящий дисплей (DISPLAY=:0); звук выключен; каждый запуск — под timeout 120 с.
set -euo pipefail
cd "$(dirname "$0")/../.."

out="${1:-docs/screenshots/gameplay}"
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"
FLY_T=20

shot() {  # shot <файл> <аргументы игры...>
  local file="$1"
  shift
  echo "-- $(basename "$file")"
  timeout 120 godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
    -- --autostart --autopilot "$@" "--screenshot=$file" 2>&1 \
    | grep -E "^screenshot:|ERROR|SCRIPT ERROR" || true
}

shot "$out/cockpit.jpg" --camera=cockpit --look=0,0.01 "--time=$FLY_T"
shot "$out/chase.jpg" --camera=chase "--time=$FLY_T"
shot "$out/free.jpg" --camera=free "--time=$FLY_T"
echo "gameplay.sh: кадры в $out"
