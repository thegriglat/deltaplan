#!/usr/bin/env bash
# Запуск тестовой сборки с тайлами OSM (OT-12).
#   tools/osm_tiles/play_local.sh                       — тайлы из R2 (configs/osm_tiles.json → base_url)
#   tools/osm_tiles/play_local.sh <каталог тайлов>       — локальный каталог (<каталог>/v1/<j>/<i>.dpt), без сети
# Дальнейшие аргументы — после «--» (аргументы игры), например:
#   tools/osm_tiles/play_local.sh "" --latlon=43.24,76.89       # Алматы (пустой первый аргумент = R2)
#   tools/osm_tiles/play_local.sh /data/tiles --latlon=43.13,77.08   # Шымбулак, локальный каталог
set -euo pipefail
BUILD="${DELTAPLAN_OSM_BUILD:-/home/greg/deltaplan/build/osm_test}"
BIN="$(ls "$BUILD"/*.x86_64 2>/dev/null | head -n1 || true)"
if [[ -z "$BIN" ]]; then
	echo "нет сборки в $BUILD (*.x86_64)" >&2
	exit 1
fi
if [[ $# -ge 1 ]]; then
	if [[ -n "$1" ]]; then
		export DELTAPLAN_OSM_TILES_URL="$1"
	fi
	shift
fi
if [[ $# -gt 0 ]]; then
	exec "$BIN" -- "$@"
fi
exec "$BIN"
