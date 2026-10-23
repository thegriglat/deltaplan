#!/bin/bash
# repair.sh <var> <lev>: удалить сутки с NaN и докачать (2 потока)
D=$(cd "$(dirname "$0")" && pwd); O=~/data/haze_humidity/era5_arco; V=~/data/haze_humidity/venv/bin/python
python3 $D/repair_nan.py $O/$1_$2 >> $O/log_repair_$1.txt
cd $D; $V fetch_arco.py $1 $2 2018-01-01 730 2 $O >> $O/log_$1_repair.jsonl 2>> $O/err_$1_repair.log
