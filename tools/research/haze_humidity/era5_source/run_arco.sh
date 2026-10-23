#!/bin/bash
# run_arco.sh <a|b>: докачка HH-18 (две цепочки по 2 потока). OUT=~/data/haze_humidity/era5_arco
D=$(cd "$(dirname "$0")" && pwd); O=~/data/haze_humidity/era5_arco; V=~/data/haze_humidity/venv/bin/python
mkdir -p $O; cd $D
if [ "$1" = a ]; then
  export DP_DIURNAL=1; $V fetch_arco.py 2m_temperature - 2018-01-01 730 2 $O >> $O/log_t2m.jsonl 2>> $O/err_t2m.log; unset DP_DIURNAL
  $V fetch_arco.py u_component_of_wind 700 2018-01-01 730 2 $O >> $O/log_u700.jsonl 2>> $O/err_u700.log
else
  $V fetch_arco.py temperature 700 2019-01-01 365 2 $O >> $O/log_t700.jsonl 2>> $O/err_t700.log
  $V fetch_arco.py v_component_of_wind 700 2018-01-01 730 2 $O >> $O/log_v700.jsonl 2>> $O/err_v700.log
fi
