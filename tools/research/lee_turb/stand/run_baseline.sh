#!/bin/sh
# Базовые разрезы LTS v1: 3 случая Онгудая × 6 гребней (ridges.json) -> out/<случай>_<гребень>.lts.csv.
# Запуск (тяжёлое, один раз):  .dpcli/dpcli lock cpu lt2 -- sh tools/research/lee_turb/stand/run_baseline.sh
# Время каждого прогона — out/times.csv. Нужен собранный dp-stand --release.
set -eu
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
HERE=$ROOT/tools/research/lee_turb/stand
OUT=$HERE/out
mkdir -p "$OUT"
BIN=$ROOT/rust/target/release/dp-stand
[ -x "$BIN" ] || cargo build -q --release --manifest-path "$ROOT/rust/Cargo.toml" -p dp-stand
python3 "$HERE/ridges.py" >/dev/null
echo "case,ridge,seconds,rows" > "$OUT/times.csv"
STEP=${STEP:-10}
for CASE in ongudai_medium ongudai_strong ongudai_storm; do
  python3 - "$HERE/ridges.json" <<'PY' > "$OUT/.list"
import json, sys
for r in json.load(open(sys.argv[1])):
    print(r["name"], "%s,%s" % tuple(r["frm"]), "%s,%s" % tuple(r["to"]), "%s,%s" % tuple(r["ys"]))
PY
  while read -r NAME FROM TO YS; do
    T0=$(date +%s)
    "$BIN" lee --case "$ROOT/tests/fixtures/wind/cases/$CASE.json" --model formula --time 0 \
      --from "$FROM" --to "$TO" --ys "$YS" --step "$STEP" --timeout 900 \
      > "$OUT/.tmp.csv" 2> "$OUT/.${CASE}_${NAME}.log"
    mv "$OUT/.tmp.csv" "$OUT/${CASE}_${NAME}.lts.csv"
    T1=$(date +%s)
    echo "$CASE,$NAME,$((T1-T0)),$(($(wc -l < "$OUT/${CASE}_${NAME}.lts.csv")-2))" >> "$OUT/times.csv"
  done < "$OUT/.list"
done
rm -f "$OUT/.list"
python3 "$ROOT/tools/research/lee_turb/contract/check_contract.py" "$OUT"/*.lts.csv
