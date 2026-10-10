#!/bin/bash
# Нарезка 2×2 по 100 км вокруг точки: скачать соседние выгрузки Geofabrik, вырезать bbox, слить,
# отфильтровать, собрать тайлы, посчитать. Большие pbf удаляются после замера (кроме Словении).
#   bash run_tiles.sh <place> <lat> <lon> <geofabrik-путь>...   (напр. europe/austria)
# Результат: $D/tiles_<place>/ и results/tiles_<place>.json
set -e
D=/home/greg/deltaplan_data/osm_pack
H=$(dirname "$(readlink -f "$0")")
PY=$D/venv/bin/python
place=$1; lat=$2; lon=$3; shift 3
W=$D/tmp_$place; mkdir -p $W
bb=$($PY -I $H/build_tiles.py bbox $lat $lon)
echo "bbox $bb"
parts=()
for u in "$@"; do
  n=$(basename $u)
  if [ "$u" = "europe/slovenia" ]; then f=$D/slovenia-latest.osm.pbf; else
    f=$D/dl_$n.osm.pbf
    [ -f $f ] || curl -sSL -o $f https://download.geofabrik.de/$u-latest.osm.pbf
  fi
  echo "$n $(stat -c %s $f) $(md5sum $f | cut -d' ' -f1) $(date -u +%FT%TZ)" >> $D/downloads.log
  osmium extract -O -s smart -b $bb -o $W/x_$n.osm.pbf $f
  parts+=($W/x_$n.osm.pbf)
  if [ "$u" != "europe/slovenia" ] && [ -z "$KEEP" ]; then rm -f $f; fi
done
if [ ${#parts[@]} -gt 1 ]; then osmium merge -O -o $W/merged.osm.pbf "${parts[@]}"; else cp ${parts[0]} $W/merged.osm.pbf; fi
osmium tags-filter -O -o $W/min.osm.pbf $W/merged.osm.pbf -e $H/filter_min.txt
ls -l $W
$PY -I $H/build_tiles.py build $W/min.osm.pbf $D/tiles_$place $lat $lon
$PY -I $H/build_tiles.py analyze $D/tiles_$place $H/results/tiles_$place.json $place
rm -rf $W
