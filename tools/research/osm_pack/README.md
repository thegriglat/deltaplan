---
type: "research"
status: "closed"
module: ""
updated: "2026-09-30"
summary: "osm_pack — замер компактного офлайн-пакета (OSM-вектор + рельеф + покров), Словения — Исследование к плану docs/plan/offline_world_data.md (этап 0)."
related: []
conclusion: ""
data: "tools/research/osm_pack/"
applied_in: ""
---
# osm_pack — замер компактного офлайн-пакета (OSM-вектор + рельеф + покров), Словения

Исследование к плану `docs/plan/offline_world_data.md` (этап 0). Итог и выводы —
`docs/plan/osm_vector_pack.md`. Код игры не трогали.

## Файлы
- `filter.txt` — выражения `osmium tags-filter` (слои пакета; без building=*, без barrier=*).
- `osmpack.py` — формат ячейки 0,25° (потоки, классы, zigzag-varint дельты) и декодер.
- `build.py` — pyosmium: классификация, сборка мультиполигонов, нарезка по ячейкам, проекция,
  Дуглас–Пейкер 1 м, квантование 1 м, запись ячеек, сжатие brotli/zstd.
- `analyze.py` — итог только по ячейкам, пересекающим границу страны; по потокам и слоям.
- `raster.py` — растеризация квадрата 10×10 км при 1 м/пикс на CPU (skia), время, картинки.
- `slovenia_rasters.py`, `terrain_cover.py` — рельеф GLO-30 и покров WorldCover в int16/uint8
  ячейках 0,25°: два пробных квадрата 0,5° и пересчёт на страну.
- `dl_rasters.sh` — (не используется в итоге: расширение на Алтай отменено) скачивание растров Алтая.
- `lc_check.py` — покров: доля общих вершин, растр классов 5/2 м против вектора.
- `summarize.py` — сводка и экстраполяция (оценка).
- `results/` — json с числами, `results/*.jpg` — картинки.

## Данные (вне репозитория, `/home/greg/deltaplan_data/osm_pack/`)
- `slovenia-latest.osm.pbf` — Geofabrik, выгрузка 2026-09-28T20:23Z, 313 335 209 байт,
  md5 e3e669d8d7622f63ee2595738d2eed27. Лицензия ODbL, © OpenStreetMap contributors.
- `slovenia-filtered.osm.pbf`, `out_slovenia/cells/*.bin` — производные (ODbL).
- `slovenia_boundary.geojson` — граница из relation 218657 (osmium getid/export).
- Copernicus GLO-30 (2 тайла, кеш `~/.cache/deltaplan_terrain/copernicus`) — © DLR/Airbus,
  Copernicus, свободная лицензия с атрибуцией. ESA WorldCover 2021 v200 (окна COG, кеш
  `~/.cache/deltaplan_terrain/cog`) — CC-BY 4.0.
- До отмены расширения скачаны (не используются): `siberian-fed-district-latest.osm.pbf`,
  `altai-*.osm.pbf`, `out_altai/` (неполный), тайлы GLO-30 Алтая в кеше.
- Полный растр 10000×10000 — `/home/greg/deltaplan_data/osm_pack/bohinj_1m.png`.

## Воспроизведение
```bash
D=/home/greg/deltaplan_data/osm_pack; cd tools/research/osm_pack
curl -sSL -o $D/slovenia-latest.osm.pbf https://download.geofabrik.de/europe/slovenia-latest.osm.pbf
osmium tags-filter -O -o $D/slovenia-filtered.osm.pbf $D/slovenia-latest.osm.pbf -e filter.txt
osmium getid -O -r $D/slovenia-latest.osm.pbf r218657 -o $D/slo_rel.osm.pbf
osmium export -O $D/slo_rel.osm.pbf --geometry-types=polygon -f geojsonseq -o $D/slo_all.geojsonseq
#   (из slo_all.geojsonseq взять объект admin_level=2 -> $D/slovenia_boundary.geojson)
P="uv run --with osmium --with shapely --with numpy --with brotli --with zstandard --with tifffile --with imagecodecs --with pillow --with skia-python"
$P python build.py $D/slovenia-filtered.osm.pbf $D/out_slovenia            # разбор 865 с + сжатие 907 с
$P python analyze.py $D/out_slovenia $D/slovenia_boundary.geojson results/slovenia_osm.json
$P python raster.py $D/out_slovenia --lat=46.29 --lon=13.88 --km=10 --px=1.0 \
    --png=$D/bohinj_1m.png --prefix=results/bohinj
$P python raster.py $D/out_slovenia --lat=46.39 --lon=13.78 --km=10 --px=1.0 --prefix=results/triglav
$P python slovenia_rasters.py results/slovenia_rasters.json    # ~83 МБ скачивания
$P python lc_check.py $D/out_slovenia results/landcover_check.json +185_+055 +184_+055 +184_+058
python3 summarize.py                                              # results/summary.{json,csv}
```
