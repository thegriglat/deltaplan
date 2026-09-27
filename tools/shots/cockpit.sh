#!/usr/bin/env bash
# Приёмка кабины (карточка docs/plan/game/01-priemka-kabiny.md): 6 фиксированных кадров на каждое
# крыло, 1920x1080, имена <крыло>_<кадр>.jpg. Чек-лист и итог — docs/screenshots/cockpit/README.md.
# tools/shots/cockpit.sh [выход] [крыло...]   (по умолчанию docs/screenshots/cockpit, все 3 крыла)
# Кадры (Онгудай, старт по умолчанию, синтетический пилот --autopilot, время симуляции):
#   F  вперёд (0,0) в полёте          DS вниз (0,−70) стоя на старте   DF вниз (0,−60) в полёте
#   U  вверх (0,+55) в полёте          B  сзади (chase) в полёте, пилот лёжа (prone)
#   TS тень крыла ниже 50 м над ровным полем — Аскарово (на Онгудае автопилот низко над ровным
#      не пролетает). Из chase тень не видна: при солнце выше ~30° она ниже нижнего края кадра
#      chase, поэтому кадр — из кабины, взгляд вправо-вниз, куда падает тень (солнце слева-сзади).
# --look задаёт голову и фиксирует её (захваченная мышь не сбивает кадр); «0,0.01» — вперёд.
# Окну нужен настоящий дисплей (DISPLAY=:0), --fullscreen — чтобы тайловый менеджер окон не
# урезал кадр; звук выключен; каждый запуск — под timeout 120 с.
set -euo pipefail
cd "$(dirname "$0")/../.."

out="${1:-docs/screenshots/cockpit}"
shift || true
wings=("$@")
[[ ${#wings[@]} -eq 0 ]] && wings=(training sport laminar)
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"

# Время снимка в полёте (с): пилот уже лёг в кокон (prone), 30–50 м над склоном.
FLY_T=20
# Кадр TS над ровным полем Аскарово: 30–45 м над землёй (время ускорено ×4); куда смотреть на тень.
TS_T=172
TS_LOOK="-100,-50"

shot() {  # shot <файл> <ускорение времени> <аргументы игры...>
  local file="$1" scale="$2"
  shift 2
  echo "-- $(basename "$file")"
  timeout 120 godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
    --time-scale "$scale" -- --autostart --autopilot --no-overlay "$@" "--screenshot=$file" 2>&1 \
    | grep -E "^screenshot:|ERROR|SCRIPT ERROR" || true
}

for w in "${wings[@]}"; do
  shot "$out/${w}_F.jpg" 1 "--wing=$w" --camera=cockpit --look=0,0.01 "--time=$FLY_T"
  shot "$out/${w}_DS.jpg" 1 "--wing=$w" --camera=cockpit --look=0,-70 --time=0.2
  shot "$out/${w}_DF.jpg" 1 "--wing=$w" --camera=cockpit --look=0,-60 "--time=$FLY_T"
  shot "$out/${w}_U.jpg" 1 "--wing=$w" --camera=cockpit --look=0,55 "--time=$FLY_T"
  shot "$out/${w}_B.jpg" 1 "--wing=$w" --camera=chase "--time=$FLY_T"
  shot "$out/${w}_TS.jpg" 4 "--wing=$w" --location=askarovo --camera=cockpit \
    "--look=$TS_LOOK" "--time=$TS_T"
done
echo "cockpit.sh: кадры в $out"
