#!/bin/bash
# PD-35: ранняя отдача (2 м) и без выравнивания с отдачей — по вариантам; строка итога на запуск → $1
OUT=$1; : > "$OUT"
D=$(dirname "$0")
run() { # имя, крыло, высота, env...
  local name=$1 w=$2 h=$3; shift 3
  local r=$("$D/gt.sh" test_pendulum_landing_technique PD27_TRACE=$w,0,$h "$@" 2>&1 | grep '→' | head -1)
  echo "$name $w $h | $r" >> "$OUT"
}
for w in training apogee laminar sport; do
  run base $w 2.0 &
  run cprev0 $w 2.0 PD35_CPREV=0 &
  wait
done
