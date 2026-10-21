#!/bin/bash
# Кадры для замера (окно, DISPLAY=:0). Выход: $OUT/*.png и META-строки в $OUT/*.log
cd "$(dirname "$0")/../../../.." || exit 1
export DISPLAY=:0 XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
OUT=${OUT:-build/dpcli/HH-3/fr}; mkdir -p "$OUT"
S=res://tools/research/haze_humidity/cloud_base
G="godot --path . --audio-driver Dummy --resolution 1920x1080"
# кучевые: Ongudai 13:00 (тонкие/средние), 30 °C; Ongudai 10:00 прохладнее (более тонкие)
$G $S/field_shot.tscn -- --autostart --bots=0 --location=ongudai --hour=13 --temp=30 --wind=3 --world-t=5400 --views=level,low,high --out=$OUT --tag=ong13 > $OUT/ong13.log 2>&1
$G $S/field_shot.tscn -- --autostart --bots=0 --location=ongudai --hour=9 --temp=22 --wind=3 --world-t=7200 --views=level,low --out=$OUT --tag=ong9 > $OUT/ong9.log 2>&1
# Cb
$G $S/storm_shot.tscn -- --autostart --bots=0 --location=ongudai --temp=34 --wind=3.9 --hour=14 --air_s=3600 --out=$OUT --views=far,mid,under --tag=cb14 > $OUT/storm.log 2>&1
# зависимость от sky_occlusion_m (тот же кадр: seed/время фиксированы)
for so in 150 700 100000; do
$G $S/field_shot.tscn -- --autostart --bots=0 --location=ongudai --hour=13 --temp=30 --wind=3 --world-t=5400 --views=low --so=$so --out=$OUT --tag=ong13so$so > $OUT/ong13so$so.log 2>&1
done
