#!/usr/bin/env bash
# Приёмка кабины (карточка docs/plan/game/01-priemka-kabiny.md): 6 фиксированных кадров на каждое
# крыло, 1920x1080, имена <крыло>_<кадр>.png. Чек-лист и итог — docs/screenshots/cockpit/README.md.
# tools/shots/cockpit.sh [выход] [крыло...]   (по умолчанию docs/screenshots/cockpit, все 3 крыла)
# Кадры (Онгудай, старт по умолчанию, синтетический пилот --autopilot):
#   F  вперёд (0,0) в полёте          DS вниз (0,−70) стоя на старте   DF вниз (0,−60) в полёте
#   U  вверх (0,+55) в полёте          B  сзади (chase) в полёте
#   TS тень крыла: chase ниже 50 м над ровным полем (Аскарово — на Онгудае автопилот
#      до ровной посадки низко не долетает)
# Окну нужен настоящий дисплей (DISPLAY=:0), --fullscreen — чтобы тайловый менеджер окон не
# урезал кадр; звук выключен; каждый запуск — под timeout.
set -euo pipefail
cd "$(dirname "$0")/../.."

out="${1:-docs/screenshots/cockpit}"
shift || true
wings=("$@")
[[ ${#wings[@]} -eq 0 ]] && wings=(training sport kingpost)
mkdir -p "$out"
export DISPLAY="${DISPLAY:-:0}"

# Время снимка в полёте (с): пилот уже лёг в кокон (prone), 30–50 м над склоном.
FLY_T=20
# Время кадра TS над ровным полем Аскарово: 30–45 м над землёй (время ускорено ×4).
TS_T=172

shot() {  # shot <файл> <ускорение времени> <аргументы игры...>
  local file="$1" scale="$2"
  shift 2
  echo "-- $(basename "$file")"
  timeout 120 godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
    --time-scale "$scale" -- --autostart --autopilot --no-overlay "$@" "--screenshot=$file" 2>&1 \
    | grep -E "^screenshot:|ERROR|SCRIPT ERROR" || true
}

for w in "${wings[@]}"; do
  shot "$out/${w}_F.png" 1 "--wing=$w" --camera=cockpit --look=0,0 "--time=$FLY_T"
  shot "$out/${w}_DS.png" 1 "--wing=$w" --camera=cockpit --look=0,-70 --time=0.2
  shot "$out/${w}_DF.png" 1 "--wing=$w" --camera=cockpit --look=0,-60 "--time=$FLY_T"
  shot "$out/${w}_U.png" 1 "--wing=$w" --camera=cockpit --look=0,55 "--time=$FLY_T"
  shot "$out/${w}_B.png" 1 "--wing=$w" --camera=chase "--time=$FLY_T"
  shot "$out/${w}_TS.png" 4 "--wing=$w" --camera=chase --location=askarovo "--time=$TS_T"
done
echo "cockpit.sh: кадры в $out"
