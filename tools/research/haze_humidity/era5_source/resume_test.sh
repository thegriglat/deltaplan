#!/bin/bash
# Проверка докачки fetch_arco.py на 6 сутках T2m (2018-07-01..06), ~4 МБ/сутки:
#  1) эталон: чистый прогон без сбоев;
#  2) прогон с внезапным убийством (SIGKILL) посреди работы + повторный запуск => сутки не перекачиваются, итог идентичен эталону;
#  3) прогон с имитацией обрывов соединения на 40 % запросов чанков (DP_FAULT=0.4) => повторы внутри процесса, итог идентичен;
#  4) битый/оборванный .tmp.npz в каталоге удаляется при старте.
P=/home/greg/data/haze_humidity/venv/bin/python; S=$(dirname "$(readlink -f "$0")")/fetch_arco.py
W=${W:-/home/greg/data/haze_humidity/era5_source/resume}; rm -rf $W; mkdir -p $W
cmp_dirs() { # хэш содержимого массивов (не файлов: zip хранит время)
  $P -I - "$1" "$2" <<'PY'
import sys, glob, os, numpy as np
a, b = sys.argv[1:3]
fa = sorted(glob.glob(a + "/*/*.npz")); fb = sorted(glob.glob(b + "/*/*.npz"))
ok = [os.path.basename(x) for x in fa] == [os.path.basename(x) for x in fb] and len(fa) > 0
for x, y in zip(fa, fb):
    u, v = np.load(x), np.load(y)
    ok &= all(np.array_equal(u[k], v[k]) for k in u.files) and u.files == v.files
print("файлов", len(fa), "идентичны" if ok else "РАЗЛИЧАЮТСЯ")
PY
}
echo "== 1. эталон"; T0=$(date +%s); $P -I $S 2m_temperature - 2018-07-01 6 2 $W/ref | tail -1; echo "эталон: $(( $(date +%s) - T0 )) с"
echo "== 2. kill -9 посреди работы"
$P -I $S 2m_temperature - 2018-07-01 6 2 $W/kill > $W/kill1.log 2>&1 &
PID=$!
until [ $(ls $W/kill/2m_temperature/*.npz 2>/dev/null | grep -vc tmp) -ge 2 ]; do sleep 0.3; done
kill -9 $PID; wait $PID 2>/dev/null
echo "после убийства готово суток: $(ls $W/kill/2m_temperature/ | grep -vc tmp)"
echo "Битый tmp" > $W/kill/2m_temperature/2018-07-06.tmp.npz   # имитация оборванной записи
$P -I $S 2m_temperature - 2018-07-01 6 2 $W/kill > $W/kill2.log 2>&1
head -1 $W/kill2.log; grep -c '"day"' $W/kill2.log | sed 's/^/докачано суток: /'
ls $W/kill/2m_temperature | grep -c tmp | sed 's/^/остатков tmp: /'
cmp_dirs $W/ref $W/kill
echo "== 3. имитация обрывов 40 %"; DP_FAULT=0.4 $P -I $S 2m_temperature - 2018-07-01 6 2 $W/fault > $W/fault.log 2>&1
echo "повторов (строк 'повтор'): $(grep -c повтор $W/fault.log)"; tail -1 $W/fault.log
cmp_dirs $W/ref $W/fault
