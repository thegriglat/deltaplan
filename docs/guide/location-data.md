---
type: "guide"
status: "active"
module: "osm-any"
updated: "2026-10-09"
summary: "Откуда берутся данные места: стадии сборки (рельеф, реки, покров, лес и вода 10 м, OSM), источники и лицензии, кеш user://locations, точка внутри встроенного места, повтор без сети, как собрать встроенное место."
related: ["docs/plan/osm-any.md", "docs/contracts/osm-any.md", "docs/guide/terrain.md", "docs/guide/world-objects.md", "docs/registry/findings.md"]
---
# Данные места: один путь для встроенных мест и любой точки

Игра на встроенном месте и на любой точке с карты получает один и тот же набор слоёв того же объёма и детальности.
Код один — сборщик места в игре (`scripts/terrain/build/`, GDScript); встроенные места — те же папки, собранные им
заранее. Формат папки — контракт OA-К1/К2 (`docs/contracts/osm-any.md`); план и решения — `docs/plan/osm-any.md`.
Python-сборки (`fetch_dem.py`, `fetch_landcover.py`, `rivers.py`, `osm_water.py`, `fetch_osm.py`) больше нет: до
удаления порт в игру доказал равенство результата (числа — `docs/registry/findings.md`, тема osm-any).

## Стадии сборки
Сборщик (`LocationBuilder`) гоняет стадии по порядку; каждая читает только файлы предыдущих и контекст
(`LocationBuildContext`, OA-К3). Тяжёлый счёт — в `WorkerThreadPool`, HTTP — `HTTPRequest`; меню и экран загрузки живы.

| Стадия | Класс | Источник | Что пишет |
|---|---|---|---|
| Рельеф | `DemStage` | detail: Copernicus GLO-30 (COG на S3, HTTP range по внутренним тайлам), 40 км, шаг 25 м, σ = 0,8 клетки; far: Terrarium z10, 160 км, шаг 100 м, detail вклеен в far | `detail.f32.zst`, `far.f32.zst` (float32, квантование 1/32 м, zstd), `meta.json` |
| Реки | `RiverStage` | сам рельеф: сток по far (priority-flood, накопление, привязка к долине), ширина от площади водосбора | `detail_water.png`, `far_water.png` (255 — русло) |
| Покров | `SurfaceStage` | ESA WorldCover 2021 (COG, HTTP range): класс узла — мода 3×3 подвыборок; лес 10 м | `detail_surface.png`, `far_surface.png` (классы игры 0..8), `detail_detail10.png` (канал L — доля леса), `surface.json` |
| OSM | `OsmStage` | Overpass API: 6 запросов по слоям на квадрат ±20 км последовательно (`[timeout]`, `[maxsize]`), перед запросом — `/api/status` и ожидание свободного слота, при 429/504 — до 5 попыток с растущей паузой и смена зеркала, тяжёлые слои при отказе — 4 тайлами; зеркала из `world_objects.json → osm.overpass_urls`, User-Agent; сырой ответ после упаковки не хранится | `osm.json` (дороги, здания, ЛЭП, реки, озёра, посёлки, поля, заборы), канал A `detail_detail10.png` (вода 10 м), `water_fraction` в `surface.json` |

Параметры сетки и шаблон конфига точки — `configs/world.json → location_builder.template` (те же значения, что у
встроенных мест). Сеть — с User-Agent из `runtime_terrain.user_agent`; блоки COG и тайлы Terrarium кешируются в
`user://terrain_cache` (повторная сборка соседнего места берёт их оттуда). Рельеф — обязательный слой: без него места
нет (сообщение, возврат в меню). Покров и OSM — по возможности, см. «Отказ слоя».

Атрибуции источников записывает сама стадия в `meta.json` (Copernicus DEM GLO-30 © DLR/Airbus/ЕС/ESA, Terrain Tiles
Mapzen/AWS Open Data), `surface.json` (© ESA WorldCover 2021, CC-BY 4.0) и `osm.json` (© OpenStreetMap contributors,
ODbL); в `ASSETS.md` — общая строка по источникам.

## Кеш `user://locations/<ключ>`
- **Ключ** — центр точки, привязанный к сетке `snap_deg` = 0,05° (≈ 5 км): `LocationCache.key_for(lat, lon)`,
  например `pt_+53.250_+058.550`. Соседние точки в одной клетке сетки берут одно место; детальный квадрат
  (±20 км) вокруг центра охватывает точку старта с запасом не меньше 17 км до края.
- **Полное место** — есть `build.json` с `complete: true` и `builder_version` равным
  `location_builder.version` (`world.json`). Версия другая — место собирается заново. `build.json` пишется последним:
  `builder_version, key, center_lat/lon, built_utc, complete, missing, seconds` (по стадиям), `net_requests, sources`.
- **Сборка** идёт во временной `user://locations/.tmp_<ключ>`, затем папка переименовывается — оборванная сборка
  не оставляет полуместо.
- **Состав папки** — как у встроенного (`meta.json`, `*.f32.zst`, `*_water.png`, `*_surface.png`,
  `detail_detail10.png`, `surface.json`, `osm.json`, `build.json`) плюс `location.json` — конфиг места по шаблону:
  `center_lat/lon`, `utc_offset_h = round(lon/15)` (часовой пояс по долготе, границы поясов не знаем), `name` —
  ближайший посёлок из OSM или координаты, `start_sites` пуст (старт — в выбранной точке по уклону).
- Все чтения конфига места и пути OSM — через `Locations` (`config`, `osm_path`, `is_builtin`, `builtin_at`).

## Отказ слоя и догрузка
- Нет покрова или OSM (сеть, сервер, ответ не разобран) — летаем без слоя: покров — процедурный, как раньше; OSM —
  без дорог, зданий и ЛЭП. В `build.json` → `missing` имя стадии, `complete: false`.
- Следующий запуск той же точки догружает **только** недостающие стадии (при пересборке покрова пересобирается и
  OSM, потому что вода 10 м ложится в канал A его файла); готовые слои сеть не трогают.
- Отказ рельефа — ошибка для пилота («нет связи», «нет данных рельефа», «здесь море»), назад в меню.

## Точка внутри встроенного места
`Locations.builtin_at(lat, lon)`: если точка не ближе `location_builder.builtin_margin_km` (10 км) к краю детального
квадрата встроенного места — грузится само встроенное место (`data/terrain/<id>/`) со стартом в точке, сборка и сеть
не нужны. Иначе — обычный путь через кеш. `location_id` в настройках и сети — id встроенного места или ключ точки.

## Повтор без сети
Полное место в кеше грузится с диска, `net_requests` = 0. Командой можно проверить: повторная сборка той же точки с
`--offline` не делает ни одного запроса; недостающее без сети остаётся в `missing`, место при этом играбельно.

## Заполнить кеш без полёта: `--prefetch`
Итоговый бинарник умеет собрать место и выйти (`PrefetchCli`, тот же `LocationBuilder`, что в игре и в
`build_location.gd`; разбор — `LaunchOptions`, аргументы после `--`, как у `--smoke`):

    deltaplan.x86_64 --headless -- --prefetch=53.23797,58.51595
    deltaplan.exe --headless -- --prefetch=53.2,58.5;47.05,11.0     (или повторить --prefetch=)
    ... --prefetch=53.23797,58.51595 --offline                       (только кеш, сеть запрещена)

В профиле пользователя собирает `user://locations/<ключ>`, дописывает недостающие стадии, печатает стадии, ключ и путь,
`итог: complete|incomplete (missing: …)`, размер, время, число запросов. Точка внутри встроенного места — об этом
сообщается (игра возьмёт встроенное), кеш всё равно собирается. Код выхода: 0 — все точки полные, 1 — нет или ошибка
разбора, 2 — точек нет. Повторный запуск того же места — 0 запросов. Запросы пишутся в лог игры (`HttpLog`, см. ниже).

## Лог сетевых запросов
Все HTTP-запросы игры идут через `HttpLog.fetch` (`scripts/core/http_log.gd`) и пишут две строки в лог игры
(`user://logs/godot.log`, у itch-установки ещё `logs/godot.log` рядом с игрой):

    HTTP > #12 POST overpass-api.de/api/interpreter [overpass roads попытка 2/5] body=388B "[out:json][timeout:180]…"
    HTTP < #12 200 48213B 1.42s [overpass roads попытка 2/5]
    HTTP < #13 ошибка result=2 (CANT_CONNECT) http=0 0B 0.05s [dem попытка 1/2]

Номер запроса, метод, хост+путь (без query и userinfo — ключи и токены не попадают), метка (стадия и попытка), для
POST — размер и начало тела (80 символов, `key/token/…=` маскируются); итог — код, размер, время или ошибка.

## Как собрать и добавить встроенное место
1. `configs/locations/<id>.json`: `name`, `center_lat/lon`, `data_dir` (`res://data/terrain/<id>`), `dem`, `surface`,
   `rivers` (взять за образец шаблон или соседнее место), `start_sites`, `landing_sites`.
2. Собрать (нужна сеть; только из рабочей копии репозитория, не в игре):
   `godot --headless --path . -s res://tools/terrain/build_location.gd -- --id <id>` — стадии как в игре, результат в
   `data_dir`, включая `osm.json` и `build.json`. Точку без конфига (для проверки кеша):
   `... -- --lat 47.05 --lon 11.0 [--offline]` в `user://locations/` (профиль для проверок —
   `XDG_DATA_HOME=$(mktemp -d)`).
3. Проверить старты и посадки (`tests/terrain/test_locations.gd`), посадки — `configs/world_objects.json → landing`,
   превью — `terrain_preview.tscn -- --location=<id>`, `world_objects_preview.tscn`.
4. Строка по данным места в `ASSETS.md`. Бюджет данных — ≤ 15 МБ на место.

## Границы
Часовой пояс — по долготе; посадки и именованные старты — только у встроенных мест (ручные данные); OSM —
квадрат ±20 км, как у детального слоя. Время сборки точки и сравнение с прежним Python-путём — в
`docs/registry/findings.md`.
