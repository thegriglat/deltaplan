#!/usr/bin/env bash
# SNW-5: кадры (4 запуска игры). Запуск: .dpcli/dpcli lock cpu SNW-5 -- $PWD/tools/research/snow_plume/SNW-5/shots.sh
d=$(dirname "$(readlink -f "$0")"); S=/home/greg/deltaplan/build/screenshots/snow-plume
EV_POSE="3500:8100:1500:100:135:40:0:0"     # z:x:дистанция:высота:азимут:ожидание:замер:смещение — с юго-востока (подветренная сторона)
SH_POSE="2500:1350:1500:100:135:40:0:0"
$d/run.sh shot_ev_strong on 27.9957,86.8285 "--wind=16,--from=270,--temp=-20,--hour=12" "everest_strong_lee:$EV_POSE" $S
$d/run.sh shot_ev_weak on 27.9957,86.8285 "--wind=2,--from=270,--temp=-20,--hour=12" "everest_weak_lee:$EV_POSE" $S
$d/run.sh shot_sh_strong on 43.128,77.081 "--wind=16,--from=270,--temp=-10,--hour=12" "shymbulak_strong_lee:$SH_POSE" $S
$d/run.sh shot_sh_weak on 43.128,77.081 "--wind=2,--from=270,--temp=-10,--hour=12" "shymbulak_weak_lee:$SH_POSE" $S
