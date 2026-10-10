---
type: "contract"
status: "active"
module: "no-osm"
updated: "2026-10-10"
summary: "Контракты no-osm: N1 файлы застройки 10 м и пятен места, N2 BuiltPatches (чтение пятен), N3 процедурные дома, N4 игра без OSM, N5 файлы места в WebP и версия кеша; К8 v4 — в easter-eggs.md"
related: ["docs/plan/no-osm.md", "docs/contracts/easter-eggs.md", "docs/contracts/osm-any.md"]
contracts: [{"id": "N1", "version": 1}, {"id": "N2", "version": 2}, {"id": "N3", "version": 1}, {"id": "N4", "version": 2}, {"id": "N5", "version": 1}]
---
# Контракты no-osm

План — `docs/plan/no-osm.md`. Менять интерфейс — только через координатора модуля (версия +1, что
изменилось, правка потребителей в том же шаге). Контрактный тест — `tests/contracts/test_no_osm_contracts.gd`
(версии — в заголовках ниже, тест сверяет). Координаты — мир места: x на восток, z на юг, м, начало — центр
места (как у `Terrain`, `surface.json → origin_*_m`). Классы — `SurfaceLayer` (BUILT = 7).

## N1. Файлы застройки места (v1, владелец NO-1; потребители N2)
В папке места (встроенное `data/terrain/<id>/` и собранное `user://locations/<ключ>/`), пишет SurfaceStage
вместе с `detail_detail10.png`, только для слоя detail:
- `detail_detail10.png` — PNG LA8 (как было): L — доля леса; **A — вода** = max(round(255 · n_w / 9), маска рек
  по рельефу на этой сетке), n_w — подвыборки 3×3 класса water (WorldCover 80). OSM в канал A не пишет.
  `surface.json → layers[detail].detail10.water_fraction` — доля клеток с A ≥ 128, `channels` — описание.
- `detail_built10.png` — PNG **L8**, та же сетка, что `detail_detail10.png` (`width`×`height`, `spacing_m` = 10,
  `origin_x_m/origin_z_m` — центр пикселя (0, 0), как у detail10). Значение = round(255 · n / 9), n — число
  подвыборок 3×3 (уровень COG 0) класса built (WorldCover 50). Нет покрова — файла нет.
- `built_patches.json`:
  ```
  {"_doc": "...", "version": 1, "source": "worldcover10", "cell_m": 10.0, "threshold": <доля 0..1>,
   "min_area_m2": <м²>, "patches": [{"id": int, "x": float, "z": float, "area_m2": float,
   "share": float, "bbox": [x0, z0, x1, z1]}]}
  ```
  Пятно — 8-связная компонента клеток с долей ≥ `threshold` (конфиг `world.json → surface.built`);
  меньше `min_area_m2` — отбрасывается. `x, z` — центр масс клеток пятна (взвешенный долей), `area_m2` —
  число клеток × 100, `share` — средняя доля 0..1, `bbox` — по краям клеток. Порядок — по `id`, `id` = 0..N−1
  в порядке обхода строк (z, затем x) первой клетки: детерминированно.
- `surface.json → layers[detail].built10 = {file, patches_file, built_fraction, patches}`.
Инварианты: сумма `area_m2` ≤ число клеток built10 с долей ≥ порога × 100; пятна не пересекаются.

## N2. `BuiltPatches` — пятна застройки в игре (v2, владелец NO-1, правка v2 — NO-9; потребители NO-2, NO-3)
v1 → v2 (10.10): публичный `static func for_dir(dir: String) -> BuiltPatches` — пятна по каталогу места без `Terrain`
(маска полян, `WorldObjects.build` без рельефа); `VillagePlacer` переходит с приватного `_load` на него.
`class_name BuiltPatches extends RefCounted`, `scripts/terrain/built_patches.gd`. Один на место, только чтение,
одинаков у всех в сети при одном месте.
- `static func for_terrain(t: Terrain) -> BuiltPatches` — загруженный для места (кеш на `Terrain`, лениво);
  `t == null` или нет файлов — пустой (`source == "none"`), без ошибок в логе.
- `static func for_dir(dir: String) -> BuiltPatches` — то же по каталогу места (`res://data/terrain/<id>/` или
  `user://locations/<ключ>/`); нет файлов — пустой.
- `source: String` — `"worldcover10"` | `"none"`.
- `patches() -> Array[Dictionary]` — копия списка N1 (`{id, x, z, area_m2, share, bbox: Rect2 (x0, z0, w, h)}`).
- `nearest(x: float, z: float) -> Dictionary` — ближайшее пятно (по центру) + `dist_m`; `{}` — пятен нет.
- `share_at(x: float, z: float) -> float` — доля застройки 0..1 в клетке 10 м (без интерполяции); 0 — вне сетки
  или нет файла.
Цена: `for_terrain` ≤ 20 мс на встроенном месте (JSON + `Image` без попиксельного обхода всего файла);
`share_at` — O(1).

## N3. Процедурные дома (v1, владелец NO-2; потребители BuildingPlacer, ObstacleIndex, поляны)
Источник домов — только пятна N2. Запись дома — как прежняя запись здания `osm.json`:
`[x, z, w, l, угол_град, высота_стен_м, крыша 0 — двускатная / 1 — плоская]`; дальше — прежние
`BuildingPlacer.place`, `building_obstacles`, штамп в маске полян. Детерминированно: rng от ключа места и `id`
пятна; плотность — по `share_at`; типы и размеры — `configs/world_objects.json → villages` (с `_doc`).
Нет пятен — домов нет.

## N4. Игра без OSM (v2, владелец NO-4; потребители сборщик, Locations, WorldObjects, пасхалки)
v1 → v2 (10.10, решение пользователя): OSM удалён и у встроенных мест — `osm.json` нет нигде.
- Стадии сборщика: dem → rivers → surface; OSM — не стадия (нет в `build.json`, не `missing`); сеть Overpass не
  используется нигде.
- Нет `osm.json`, `OsmData`, `OsmLayer`, `RoadMesher`, `Locations.osm_path`; дорог, ЛЭП, заборов, полей, имён
  посёлков и воды OSM нет. Вода — только N1 (канал A) и реки по рельефу; здания — только N3.
- Подъезды к стартам (`start_tracks`) — без дорог OSM: процедурно, если это уже умеет код, иначе убраны.
- Имя места — `configs/locations/<id>.json → name` (встроенное) или координаты точки.
- Встроенные места собираются и летаются так же, как произвольная точка (те же файлы, кроме `osm.json`).

## N5. Файлы места в WebP и версия кеша (v1, владелец NO-9; потребители HeightLayer, SurfaceLayer, Terrain, сборщик, NO-8)
Основа — `docs/research/location_compression.md`. Совместимость со старыми файлами не нужна.
- **Высоты** слоя (`detail`, `far`): `<id>.webp`, WebP lossless, RGB8; код v = (R << 16) | (G << 8) | B,
  высота h = `height_min_m` + v · `height_step_m`, шаг 1/8 м (0,125), ошибка ≤ 0,0625 м против float32. `height_min_m`,
  `height_step_m`, имя файла — в описании слоя (`meta.json`/info слоя, там же, где сейчас размер и шаг сетки).
- **Остальные растры места** (`<id>_surface`, `<id>_water`, `detail_detail10`, `detail_built10`): `.webp` lossless с
  теми же значениями и каналами, что прежние PNG (L8 / LA8); читатель после загрузки приводит к прежнему формату
  (`Image.convert`), значения побитово те же. У LA8 (detail10) RGB под нулевой альфой обнуляется перед сохранением.
- **Версия формата места**: одна константа `Locations.FORMAT_VERSION` (int; комментарий «поднимать при любом изменении
  файлов места») пишется в `build.json → format_version`. При открытии кеша `user://locations/<ключ>/` несовпадение
  (или нет поля) → каталог удаляется целиком, место собирается заново (не догрузка стадий). Сейчас — поднята.
- **Версия источника** сырых блоков (`user://terrain_cache/…`, COG/Terrarium) — отдельная константа; сброс кеша блоков
  только при её смене (меняется источник или нарезка), не при смене `FORMAT_VERSION`.
