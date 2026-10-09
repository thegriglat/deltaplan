---
type: "contract"
status: "active"
module: "osm-any"
updated: "2026-10-09"
summary: "Контракты osm-any: папка места (встроенного и кешированного), файл OSM места, API стадий сборки места в игре, сборщик/кеш/реестр мест."
related: ["docs/plan/osm-any.md", "docs/guide/world-objects.md", "docs/guide/architecture.md"]
contracts: [{"id": "OA-К1", "version": 1}, {"id": "OA-К2", "version": 1}, {"id": "OA-К3", "version": 1}, {"id": "OA-К4", "version": 1}]
---
# Контракты модуля osm-any

План — `docs/plan/osm-any.md`. Менять — только через координатора (версия +1, что изменилось, уведомить
потребителей). Контрактный тест — `tests/contracts/test_osm_any_contracts.gd` (без сети и GPU; фильтр `osm_any`).
Части, которых ещё нет в коде, в тесте падают — их делают зелёными задачи-владельцы.

Общее: мир — X восток, Z юг (−Z север), Y вверх, м; начало X/Z — центр места; проекция — равнопромежуточная вокруг
центра, R = 6371008,8 м (как `fetch_dem.py`). Растры — строки с севера, столбцы с запада; узел (i, j) =
(origin_x + i·spacing, origin_z + j·spacing).

## OA-К1. Папка места (v1)
Владельцы: Python-сборка (встроенные, `data/terrain/<id>/`), OA-1/OA-2/OA-3/OA-4 (кеш, `user://locations/<ключ>/`).
Потребители: `terrain.gd` (`load_location`), `surface_layer.gd`, `world_objects`, `world_clearings`, контрактный тест.
Набор файлов (одинаков для встроенного и кешированного, кроме расширения высот):
- `meta.json` — `{location, center_lat, center_lon, earth_radius_m, layers:[{id, file, width, height, spacing_m,
  origin_x_m, origin_z_m, min_height_m, max_height_m, source, water_file}], attribution:[String]}`; слои `detail`, `far`
  в этом порядке.
- высоты слоя `<id>`: встроенные — `<id>.f32.br` (brotli), кеш — `<id>.f32.zst` (сырой кадр zstd от
  `PackedByteArray.compress(FileAccess.COMPRESSION_ZSTD)`); внутри — float32 LE, width×height, строки с севера,
  квантованы до 1/`quantize_per_m` м. `HeightLayer.load_from_file` выбирает распаковку по расширению.
- `<id>_water.png` — L8 width×height слоя, 255 — русло (реки по рельефу), 0 — нет.
- `<id>_surface.png` — L8 width×height слоя, классы 0..8 игры (`configs/world.json → surface.worldcover.classes`).
- `detail_detail10.png` — LA8, шаг 10 м, квадрат detail (4001×4001 при 40 км): L — доля леса 0..255, A — доля воды
  0..255 (из OSM).
- `surface.json` — `{source, layers:[{id, file, width, height, spacing_m, origin_x_m, origin_z_m, class_fraction:{"0".."8"},
  detail10?:{file, width, height, spacing_m, origin_x_m, origin_z_m, channels, forest_fraction, water_fraction}}], attribution}`.
- Только у кеша: `location.json` (конфиг места, OA-К4), `osm.json` (OA-К2), `build.json` (OA-К4).
После OA-7 встроенные места собираются тем же сборщиком и переходят на формат кеша (`.f32.zst`, `osm.json` в папке;
`data/osm/` удаляется) — это правка OA-К1/OA-К2 до v2 вместе с OA-7.
Параметры сетки кеша — те же, что у встроенных (`configs/world.json → location_builder.template.dem.layers`):
detail 40 км / 25 м / copernicus / σ 0,8 / 1/32 м; far 160 км / 100 м / terrarium z10 / вклейка detail.

## OA-К2. Файл OSM места (v1)
Владельцы: `tools/osm/fetch_osm.py` (встроенные, `data/osm/<id>.json`), OA-4 (кеш, `user://locations/<ключ>/osm.json`).
Потребители: `OsmData.load_file` и всё за ним (`world_objects`, `osm_layer`, `world_clearings`, `start_tracks`,
`egg_place`, `recent_places`), OA-4 (канал воды).
- UTF-8 JSON-объект, ключи: `attribution` (String), `location` (id или ключ кеша), `center_lat`, `center_lon` (float),
  `bbox_latlon` ([юг, запад, север, восток]), `roads`, `buildings`, `power`, `water:{rivers, lakes}`, `places`,
  `landuse:{fields, fences}`; `_doc` — необязателен. Все координаты — мир места, м, округление 0,1 м.
- Элементы — как в `docs/guide/world-objects.md`, раздел OSM, и упаковщиках `fetch_osm.py`
  (`pack_roads/buildings/power/water/places/landuse`): `roads[{t,p}]`, `buildings[[x,z,w,l,угол,высота,крыша]]`,
  `power[{k,v,c,p,s}]`, `rivers[{t,n,p}]`, `lakes[{n,p,h}]`, `places[{n,t,x,z,pop}]`, `fields[{t,p}]`, `fences[{t,p}]`.
- Квадрат запроса — ±(половина detail) от центра (±20 км). Пустой слой — пустой массив, не отсутствие ключа.
- Инвариант паритета: упаковщик игры на тех же ответах Overpass даёт тот же JSON, что `fetch_osm.py`.

## OA-К3. API стадий сборки места (v1)
Владелец: координатор (интерфейс), реализации — OA-1…OA-4, вызывающий — OA-5.
```
class_name LocationBuildContext extends RefCounted   # scripts/terrain/build/location_build_context.gd
var key: String                 # ключ места (OA-К4)
var center_lat: float           # градусы WGS84 (центр, привязанный к сетке)
var center_lon: float
var dir: String                 # папка, куда стадия пишет файлы (временная, user://…)
var spec: Dictionary            # конфиг места (как configs/locations/<id>.json: dem.layers, surface.layers, rivers…)
var host: Node                  # узел в дереве для HTTPRequest
var offline: bool = false       # true — сеть запрещена: только кеши/локальные файлы, иначе ERR_UNAVAILABLE
var cancelled: bool = false     # стадия проверяет между шагами и выходит с ERR_SKIP
var heights: Dictionary = {}    # id слоя → PackedFloat32Array (после стадии рельефа)
var layers: Dictionary = {}     # id слоя → словарь слоя из meta.json
var net_requests: int = 0       # число сетевых запросов стадий (для проверки «из кеша — без сети»)
var log_lines: PackedStringArray
signal progress(stage: String, fraction: float)   # 0..1 внутри стадии
```
Стадии — `RefCounted` с методом `func run(ctx: LocationBuildContext) -> Error` (вызывается через `await`),
файлы `scripts/terrain/build/`:
1. `DemStage` (`dem_stage.gd`, OA-1): пишет `detail.f32.zst`, `far.f32.zst`, `meta.json`; заполняет `ctx.heights`,
   `ctx.layers`.
2. `RiverStage` (`river_stage.gd`, OA-2): из `ctx.heights`/`ctx.layers` и `spec.rivers` пишет `<id>_water.png`.
   Ядро без контекста: `static func compute(heights: Dictionary, layers: Dictionary, cfg: Dictionary) -> Dictionary`
   (id слоя → `Image` L8).
3. `SurfaceStage` (`surface_stage.gd`, OA-3): пишет `<id>_surface.png`, `detail_detail10.png` (A = 0),
   `surface.json` (`water_fraction` = 0).
4. `OsmStage` (`osm_stage.gd`, OA-4): пишет `osm.json`, заполняет A в `detail_detail10.png` и `water_fraction`.
   Ядра без сети: `static func pack(elements: Array, center_lat: float, center_lon: float, half_m: float) -> Dictionary`
   (элементы ответа Overpass → OA-К2), `static func water_alpha(osm: Dictionary, info10: Dictionary) -> Image`.
Правила: стадия читает только файлы предыдущих стадий и `ctx`; ошибка — код `Error` и строка в `ctx.log_lines`;
тяжёлый счёт — вне главного потока (`WorkerThreadPool`/`Thread`), HTTP — `HTTPRequest` под `ctx.host`; сеть — с
User-Agent `configs/world.json → runtime_terrain.user_agent`, таймаут, кеш блоков/тайлов в `user://terrain_cache`;
каждый запрос в сеть — `ctx.net_requests += 1`. Источник COG — URL или локальный путь (для проверок без сети).

## OA-К4. Сборщик, кеш и реестр мест (v1)
Владелец: OA-5. Потребители: `game.gd`, `flight_setup_screen`, `world_link`, `world_objects`, `world_clearings`,
`recent_places`, `user_settings`, `world_key`, `activity`, `favorites`, `start_menu`, `task_preview`.
- `LocationCache.key_for(lat, lon) -> String`: центр = округление lat и lon к шагу
  `configs/world.json → location_builder.snap_deg` (0,05°); ключ `"pt_%+07.3f_%+08.3f" % [lat, lon]` центра
  (`key_for(53.26, 58.54) == "pt_+53.250_+058.550"`, `key_for(-5.51, -0.02) == "pt_-05.500_-000.000"` →
  ноль без знака минус: `"pt_-05.500_+000.000"`).
- `LocationCache.dir_for(key) -> String` = `user://locations/<key>`. Место полное ⇔ есть `build.json` с
  `complete: true` и `builder_version == location_builder.version`. `build.json`:
  `{builder_version, key, center_lat, center_lon, built_utc, complete, missing:[String], seconds:{стадия: с},
  net_requests, sources:[String]}` — пишется последним; сборка — во `user://locations/.tmp_<key>`, затем переименование.
- `LocationBuilder.build(host: Node, lat: float, lon: float) -> Dictionary` (`await`): `{ok: bool, key, error: String,
  missing: Array}`; сигнал `progress(stage, fraction)`. Полное место — сразу, `net_requests == 0`. Неполное (`missing`) —
  догружаются только недостающие стадии.
- `Locations.config(id) -> Dictionary` — встроенный `configs/locations/<id>.json` или `user://locations/<id>/location.json`;
  `Locations.osm_path(id)`, `Locations.is_builtin(id)`, `Locations.builtin_at(lat, lon) -> String` (встроенное место, у
  которого точка не ближе `location_builder.builtin_margin_km` (10) к краю detail, иначе `""`).
  Все чтения `Config.get_config("locations/" + …)` и `res://data/osm/<id>.json` — через `Locations`.
- `location.json` — конфиг места по шаблону `location_builder.template` (+ `center_lat/lon`, `utc_offset_h` =
  `round(lon/15)`, `data_dir` = папка места, `name` = ближайший посёлок из OSM или координаты, `start_sites` = []).
- Точка старта (`pick_lat/lon`) остаётся в настройках и сети как сейчас; `location_id` = id встроенного места или ключ.
