#!/bin/bash
# Разовое скачивание растров для замера пакета рельефа/покрова (вне репозитория).
# Copernicus GLO-30 (1°) -> ~/.cache/deltaplan_terrain/copernicus (тот же кеш, что tools/terrain/fetch_dem.py)
# ESA WorldCover 2021 v200 (3°) -> /home/greg/deltaplan_data/osm_pack/worldcover
set -u
COP=$HOME/.cache/deltaplan_terrain/copernicus
WC=/home/greg/deltaplan_data/osm_pack/worldcover
mkdir -p "$COP" "$WC"
get() { [ -s "$2" ] && return 0; curl -sSfL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2" || echo "FAIL $1"; }
cop() { # $1 lat, $2 lon (целые, >=0)
  local n; n=$(printf "Copernicus_DSM_COG_10_N%02d_00_E%03d_00_DEM" "$1" "$2")
  get "https://copernicus-dem-30m.s3.amazonaws.com/$n/$n.tif" "$COP/$n.tif"
}
for lat in 49 50 51 52; do for lon in 84 85 86 87 88 89; do cop $lat $lon & done; wait; done
for lat in 45 46; do for lon in 13 14 15 16; do cop $lat $lon & done; done; wait
for t in N48E084 N48E087 N51E084 N51E087 N45E012 N45E015; do
  get "https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/ESA_WorldCover_10m_2021_v200_${t}_Map.tif" "$WC/ESA_WorldCover_10m_2021_v200_${t}_Map.tif" &
done; wait
ls -la "$COP" "$WC"
