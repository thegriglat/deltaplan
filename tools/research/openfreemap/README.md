---
type: "research"
status: "closed"
module: "osm-any"
updated: "2026-10-10"
summary: "Сравнение векторных тайлов OpenFreeMap z14 с эталоном osm.json (Overpass) на месте aushkul: скрипты и числа."
related: ["docs/research/openfreemap_vs_overpass.md"]
conclusion: "см. docs/research/openfreemap_vs_overpass.md"
data: "results/"
applied_in: "не применено"
---
# OpenFreeMap vs Overpass (aushkul)

Вывод и таблицы — `docs/research/openfreemap_vs_overpass.md`. Данные тайлов — вне репо: `/home/greg/deltaplan_data/openfreemap/` (кеш `tiles/aushkul/*.pbf` как пришло по сети, 1,09 МБ; `ofm_aushkul.pkl`; venv).
Лицензия данных: ODbL (© OpenStreetMap contributors) + схема © OpenMapTiles; атрибуция OpenFreeMap/OpenMapTiles/OSM обязательна.

Воспроизведение (venv: `uv venv venv && uv pip install mapbox-vector-tile shapely numpy matplotlib requests`; Python, читающий скачанное, — с `-I` где возможно):
```
V=/home/greg/deltaplan_data/openfreemap/venv/bin/python
cd tools/research/openfreemap
$V fetch.py aushkul     # results/fetch_aushkul.json (3 потока, UA deltaplan-research)
$V decode.py aushkul    # MVT -> метры места (проекция как osm_stage.gd Proj)
$V compare.py aushkul   # results/compare_aushkul.json (~3 мин, shapely)
$V overlay.py           # results/overlay_roads.jpg
```
