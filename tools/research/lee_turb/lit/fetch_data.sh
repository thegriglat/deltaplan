#!/bin/sh
# Скачивает открытые данные экспериментов в lit/data/ (в git не кладутся). Запуск: sh fetch_data.sh
set -e
cd "$(dirname "$0")"; mkdir -p data/hill
T=https://tmbwg.github.io/turbmodels
for f in profiles.exp.dat cf.exp.dat; do curl -sL -o data/$f $T/Backstep_validation/$f; done
for f in delville_exp_u delville_exp_delomega delville_exp_turb; do curl -sL -o data/$f.dat $T/Delvilleshear_grids/$f.dat; done
# KBwiki UFR 3-30: ссылки на файлы CR-001..010 берутся со страницы (адреса содержат хеш-каталоги)
curl -sL -A 'Mozilla/5.0' 'https://kbwiki.ercoftac.org/w/index.php?title=UFR_3-30_Test_Case' > data/hill.html
grep -oE 'https://kbwiki-images[^"]*UFR3-30_X_(10600|37000)_data_CR-0[0-9][0-9]\.dat' data/hill.html | sort -u | while read u; do curl -sL -o data/hill/$(basename $u) "$u"; done
