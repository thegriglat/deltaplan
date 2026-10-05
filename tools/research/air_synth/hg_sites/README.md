---
type: "reference"
status: "active"
module: "air-synth"
updated: "2026-10-05"
summary: "Каталог стартов дельтаплана из OSM (S6): все старты, неясные, только параплан, места 10 км, выжимка для игры; команды выгрузки и сборки"
related: ["docs/contracts/air-synth.md"]
---
# Каталог мест дельтаплана из OSM (контракт S6 v1+)

Задача SY-9 модуля air-synth. Основа набора мест для обучения сети ветра: где реально летают на дельтаплане.
Цифры и дата выгрузки — `summary.json` / `summary.md` (дата — `fetch_date_utc`).

## Файлы
| файл | что |
|---|---|
| `takeoffs.csv` | ВСЕ старты дельтаплана (`free_flying:hanggliding=yes` или `free_flying:rigid=yes`), строка на старт, без объединения; столбцы S6 + `country_name`, `country_name_ru`; все `free_flying:*` теги в `tags` (JSON) |
| `unclear.csv` | старты без тегов `hanggliding`/`rigid`/`paragliding` — «неясно», все, те же столбцы (`site_id` пуст) |
| `paraglide_only.csv` | для проверки: старты только параплана (`hanggliding=no`, либо только `paragliding=yes`) — в каталог не входят; хранятся, чтобы решение «только параплан → не брать» можно было пересмотреть без новой выгрузки |
| `sites.json` | места: кластеры стартов `takeoffs.csv` < 10 км (односвязно); `tile_hint` — квадрат ±20 км для конвейера П6; `relief_m` |
| `takeoffs_game.json` | компактная выжимка для игры: `{id, name, lat, lon, country, ele, orientation}` по всем стартам дельтаплана |
| `summary.json`, `summary.md` | сводка (страны, перепад, отброшено по видам, число запросов) |
| `catalog.py`, `fetch.py`, `build.py`, `tests/` | код и тесты |

## Правило отбора (по вики OSM, Tag:sport=free_flying, проверено 05.10.2026)
- Старт: `free_flying:site` содержит `takeoff` (в т. ч. составные `takeoff;toplanding`) **или** `free_flying:takeoff=yes`
  (новая схема вики: `site=takeoff` помечено deprecated и заменяется на `free_flying:takeoff=yes`). Точки (node) и
  полигоны/отношения (центр bbox геометрии). Отклонение от S6-текста: добавлена новая схема тегов — иначе новые
  объекты потерялись бы.
- Старые теги `sport=hang_gliding` / `sport=paragliding` / `leisure=…` в вики по этой теме не описаны как старт
  → не используются. Ориентация: `free_flying:site_orientation`, при отсутствии — `direction` (замена по вики).
- Дельтаплан: `free_flying:hanggliding=yes`, а также `free_flying:rigid=yes` (жёсткое крыло) при отсутствии `hanggliding=no`.
  `hanggliding=no` или только `paragliding=yes` → параплан (не берём). `hanggliding=discouraged` → отдельно (не берём).
  Тегов нет вовсе → `unclear.csv`.
- Не берутся: посадки, верхние посадки без старта, буксировка, учебные площадки, объекты `free_flying:site` без
  `takeoff` (число по видам — `n_dropped_by_kind` в сводке).
- Страна: `is_in(lat,lon)` Overpass → область `admin_level=2` с `ISO3166-1` (пусто — море/спорные территории);
  названия стран — `name:en`/`name:ru` тех же границ.
- `relief_m`: max−min высот Terrarium z9 по пикселям в квадрате ±20 км вокруг центра места (грубо: пиксель
  ~300 м·cos(широты); перепад занижен относительно сетки 100 м).

## Воспроизведение
```
cd tools/research/air_synth/hg_sites
sh ../corpus/setup_env.sh && ../corpus/.venv/bin/python -m pip install pillow   # Pillow нужен для PNG Terrarium (uv pip install --python ../corpus/.venv/bin/python pillow)
../corpus/.venv/bin/python build.py fetch        # Overpass: один запрос на весь мир (~6 тыс. элементов), кеш
../corpus/.venv/bin/python build.py countries    # is_in пачками по 100 точек, паузы 6 с, кеш
../corpus/.venv/bin/python build.py relief       # тайлы Terrarium z9, кеш
../corpus/.venv/bin/python build.py build        # детерминированная сборка файлов (без сети)
../corpus/.venv/bin/python -m pytest -q tests
```
Кеш — `~/.cache/deltaplan_osm/hg_sites/` (вне git). Повторный `build` по тому же кешу даёт побитно те же файлы;
`build.py fetch --refresh` — новая выгрузка (обновить дату здесь и в сводке). Клиент Overpass —
`tools/osm/fetch_osm.py → overpass()` (зеркала по кругу, User-Agent), для пакетных запросов стран — тонкая обёртка в
`fetch.py` с теми же зеркалами. Заметка 05.10: серверы Overpass отвечали медленно (504/429), поэтому один глобальный
запрос вместо тайлов 20° × 20° (тайловый вариант упёрся в таймауты).

## Лицензии
Данные: © OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright); производная база
(этот каталог) — тоже ODbL при распространении. Высоты для `relief_m`: Terrain Tiles (Mapzen/AWS Open Data; SRTM,
GMTED2010 и др., https://github.com/tilezen/joerd/blob/master/docs/attribution.md); сами тайлы не в git.
Строка в `ASSETS.md`.
