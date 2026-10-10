---
type: "research"
status: "closed"
module: "terrain"
updated: "2026-10-10"
summary: "Озёра: WorldCover 10 м против OSM на Аушкуле, Алтае, Онгудае, Аскарове — площади воды на каждом шаге сборки и в H, IoU, где WorldCover воду не видит."
conclusion: "WorldCover видит озёра (IoU с OSM по крупным озёрам 0,86–0,97); вода не теряется ни в SurfaceStage, ни в снимке узлов, ни в H. Итог: docs/research/lakes_worldcover.md."
---

# lakes_worldcover

Вопрос: нужны ли озёра из OSM, если WorldCover их видит. Итог — `docs/research/lakes_worldcover.md`.

## Воспроизведение

Из корня рабочей копии, `PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python`:

```
cd tools/research/lakes_worldcover
$PY -I wc_fetch.py aushkul altai ongudai askarovo   # ~1 мин на место, нужна сеть (S3 range-запросы); пишет cache/wc_<место>.npz (в git не кладётся)
$PY -I analyze.py                                   # results/<место>.json
$PY -I figure_iou.py                                # results/proposal_iou.json, results/aushkul_masks.jpg
```

Входы: `data/terrain/<место>/{osm.json, detail_surface.png, detail_detail10.png, detail_water.png, meta.json}` (собраны игрой, в репозитории).

## Данные и лицензии

- ESA WorldCover 2021 v200, © ESA WorldCover project / Copernicus Sentinel data, CC-BY 4.0; читается с `s3://esa-worldcover` по HTTP range (без скачивания целых файлов).
- OSM (osm.json встроенных мест) — © участники OpenStreetMap, ODbL.
- В git — только скрипты, `results/*.json`, один jpg; `cache/` (npz окна WorldCover, ~30 МБ) пересоздаётся.

## Метод (коротко)

- WorldCover на сетке detail10 (4001², 10 м, начало −20 км) с k = 3 подвыборками на клетку, как `SurfaceStage._detail10`; вода = код 80; клетка — вода при ≥ 0,5.
- Озёра OSM — полигоны `osm.json: water.lakes` (с островами-дырами), растр PIL на той же сетке (без суперсэмплинга: ошибка кромки порядка ±½ клетки).
- Снимок узлов 25 м и доля воды в круге 10 км — как `AirPlace` / `measure.gd` surface-heat: класс 25 м == 6 ∪ маска рек (`detail_water.png` > 127) ∪ канал A (билинейно, ≥ 127,5).
