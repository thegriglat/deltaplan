#!/usr/bin/env bash
# SNW-9: вторая серия near — вид сбоку (ветер поперёк кадра), камера низко. Под замком cpu.
d=$(dirname "$(readlink -f "$0")"); SCR=${SCR:-/tmp/claude-1000/snw9}
P="near_d:%s:%s:12:3:180:45:0:2;near_e:%s:%s:20:4:180:5:0:6"
$d/run.sh ev_strong2 on 27.9957,86.8285 "--wind=16,--from=270,--temp=-20,--hour=12" "$(printf "everest_strong_$P" 4200 8150 4200 8150 | sed 's/;near_e/;everest_strong_near_e/')" $SCR
$d/run.sh sh_strong2 on 43.128,77.081 "--wind=16,--from=270,--temp=-10,--hour=12" "$(printf "shymbulak_strong_$P" 2800 1350 2800 1350 | sed 's/;near_e/;shymbulak_strong_near_e/')" $SCR
