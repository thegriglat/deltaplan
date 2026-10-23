#!/usr/bin/env bash
# SNW-9: кадры струек v3. Запуск: .dpcli/dpcli lock cpu SNW-9 -- $PWD/tools/research/snow_plume/SNW-9/shots.sh
# Кадры сначала в $SCR, потом выбранные копируются в /home/greg/deltaplan/build/screenshots/snow-plume (см. README).
d=$(dirname "$(readlink -f "$0")"); SCR=${SCR:-/tmp/claude-1000/snw9}
# поза: имя:z:x:дистанция:высота_камеры:азимут:ожидание:замер:смещение_цели (z,x — игровые, м; азимут — откуда смотрим, ° от севера)
EV_LEE="3500:8100:1500:100:135:45:0:0"; SH_LEE="2500:1350:1500:100:135:45:0:0"
# near: цель — источник на гребне (Эверест z=4200 x=8150 y=8405; Шымбулак z=2800 x=1350 y=3435), ветер на восток
EV="4200:8150"; SH="2800:1350"
nearposes() { echo "$1_near_a:$2:20:8:135:45:0:3;$1_near_b:$2:25:10:180:5:0:3;$1_near_c:$2:15:6:225:5:0:2"; }
$d/run.sh ev_strong on 27.9957,86.8285 "--wind=16,--from=270,--temp=-20,--hour=12" "everest_strong_lee:$EV_LEE;$(nearposes everest_strong $EV)" $SCR
$d/run.sh ev_weak on 27.9957,86.8285 "--wind=2,--from=270,--temp=-20,--hour=12" "everest_weak_lee:$EV_LEE" $SCR
$d/run.sh sh_strong on 43.128,77.081 "--wind=16,--from=270,--temp=-10,--hour=12" "shymbulak_strong_lee:$SH_LEE;$(nearposes shymbulak_strong $SH)" $SCR
$d/run.sh sh_weak on 43.128,77.081 "--wind=2,--from=270,--temp=-10,--hour=12" "shymbulak_weak_lee:$SH_LEE" $SCR
