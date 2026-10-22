#!/bin/bash
# Основной замер: ARCO 1° почасовой, 2018-06/07. Сырьё вне репозитория.
P=/home/greg/data/haze_humidity/venv/bin/python; O=${O:-/home/greg/data/haze_humidity/era5_source}; S=$(dirname "$0")/fetch_arco.py
$P -I $S 2m_temperature - 2018-06-01 61 3 $O/B
$P -I $S temperature 700 2018-07-01 31 3 $O/B
$P -I $S u_component_of_wind 700 2018-06-01 10 3 $O/B
