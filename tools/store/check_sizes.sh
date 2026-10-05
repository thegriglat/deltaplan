#!/usr/bin/env bash
# Проверка размеров файлов steam/store/ по контракту SA-К4 (docs/contracts/steam-assets.md). Владелец — координатор steam-assets.
cd steam/store || exit 1
ok=1
for p in capsule_header.jpg:920x430 capsule_small.jpg:462x174 capsule_main.jpg:1232x706 capsule_vertical.jpg:748x896 page_background.jpg:1438x810 library_capsule.jpg:600x900 library_header.jpg:920x430 library_hero.png:3840x1240 shortcut_icon.png:256x256 app_icon.jpg:184x184 event_cover.jpg:800x450 event_header.jpg:1920x622; do f=${p%%:*}; want=${p##*:}; got=$(identify -format '%wx%h' "$f" 2>/dev/null); [ "$got" = "$want" ] || { echo "BAD $f $got != $want"; ok=0; }; done
read w h a < <(identify -format '%w %h %A' library_logo.png); { [ "$w" = 1280 ] && [ "$h" -le 720 ] || [ "$h" = 720 ] && [ "$w" -le 1280 ]; } && [ "$a" != "Undefined" ] && [ "$a" != "False" ] || { echo "BAD library_logo $w $h $a"; ok=0; }
identify shortcut_icon.ico | grep -q '256x256' || { echo "BAD ico"; ok=0; }
test -f .gdignore && test -s README.md || { echo "BAD gdignore/README"; ok=0; }
[ $ok = 1 ] && echo "STORE SIZES OK"
