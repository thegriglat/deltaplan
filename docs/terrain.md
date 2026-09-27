# Рельеф и мир

FR-17…FR-20, NFR-1, NFR-2. Исследование источников — [research/terrain_sources.md](research/terrain_sources.md).

## Что где
| Файл | Что делает |
|---|---|
| `scripts/terrain/terrain.gd` (`Terrain`, группа `"terrain"`) | нода рельефа: загрузка локации, контракт `height_at / normal_at / get_start_sites / sun_exposure_at` |
| `scripts/terrain/height_layer.gd` (`HeightLayer`) | сетка высот, билинейная выборка (RefCounted, тестируется headless) |
| `scripts/terrain/geo.gd` (`TerrainGeo`) | lat/lon ↔ мир, направление солнца, вектор курса |
| `scripts/terrain/terrain_renderer.gd` (`TerrainRenderer`) | чанки + LOD, материалы, текстуры поверхностей |
| `scripts/terrain/terrain.gdshader` + `terrain_common.gdshaderinc` | высоты в вершинном шейдере, раскраска (трава, лес, поля, скалы, снег, реки) |
| `scripts/terrain/terrain_trees.gd` + `trees.gdshader` (`TerrainTrees`) | 3D-деревья вокруг камеры (GPU-инстансинг) |
| `scripts/terrain/terrarium_loader.gd` (`TerrariumLoader`) | рантайм-загрузка рельефа по lat/lon (FR-17), кеш `user://terrain_cache` |
| `scripts/terrain/map_picker.gd` + `map_hillshade.gdshader` (`MapPicker`) | карта выбора точки: отмывка из Terrarium, щелчок / ввод координат → `point_picked(lat, lon)` |
| `scripts/world/sky_environment.gd` (`SkyEnvironment`), `scenes/world/environment.tscn` | небо, солнце с мягкими тенями, дымка, glow |
| `scenes/terrain/terrain_preview.tscn`, `map_picker_preview.tscn` | отдельный запуск модуля |
| `tools/terrain/fetch_dem.py`, `rivers.py` | подготовка данных встроенной локации |
| `configs/locations/<id>.json` | локация: центр, слои DEM, LOD, старты, реки |
| `configs/world.json` | солнце, небо, дымка, эффекты, вид рельефа, деревья, текстуры, рантайм-загрузка, карта |

## Как устроено
**Данные.** Локация — несколько вложенных квадратных слоёв высот (детальный 40 км / 25 м из Copernicus GLO-30,
фон 160 км / 100 м из Terrarium). Файл слоя — float32 LE, gzip (`<слой>.f32.gz`), строки с севера на юг.
Узлы слоёв выровнены, грубый слой в зоне детального содержит его же высоты → на стыке нет ступеньки.
Загрузка «Алтая» — 0.2–0.3 с (NFR-2: ≤ 10 с): распаковка + `to_float32_array()` + текстура `FORMAT_RF`.

**`height_at`** — билинейная интерполяция самого детального слоя, покрывающего точку; за краем — край грубого.
≈1.6 мкс на вызов (10 000 вызовов — 16 мс). В узлах совпадает с данными до 1 см (тест).
**`normal_at`** — центральные разности с шагом сетки. **`sun_exposure_at`** = `clamp(dot(normal, sun_dir), 0, 1)`,
солнце — `configs/world.json → sun` (азимут/высота). Ровная площадка при солнце 52° → 0.79.
**Старты** — из `start_sites` локации (lat/lon/курс), высота = земля + `start_position_agl_m`.

**Меш.** Слой режется на чанки (`render.<слой>.chunk_cells`); у всех чанков слоя общие плоские сетки LOD
(шаг 1, 2, 4… клетки), высоту даёт вершинный шейдер через `texelFetch` → построение мгновенное.
LOD выбирается по расстоянию от камеры до AABB чанка (`lod_distances_m`) раз в `lod_update_interval_s`.
Щели между LOD закрывает «юбка». Коллизии нет — полёт использует `height_at`.

**Раскраска** (FR-19) процедурная: уклон и экспозиция по сглаженной нормали (ступеньки леса в DSM не красятся в скалы),
лес — пятна шума с перевесом на северных склонах и границей по высоте, поля — прямоугольные участки на пологом дне долин,
скалы по уклону, снег выше `snowline_m`, реки — маска из `rivers.py`. Вблизи — шум детализации, рельеф крон,
CC0-текстуры травы и скал (их рисунок, цвет остаётся процедурным — без шва вдали). Вокруг стартов — поляны.
Деревья: сетка экземпляров едет с камерой, дерево привязано к мировой клетке; где лес — решает та же функция
`biome()`, что и раскраска. Деревья утоплены в поверхность (`sink_fraction`), т. к. DEM — это DSM с кронами.

**Мир.** `SkyEnvironment`: ProceduralSky, солнце с 4 каскадами теней (3 км) и полутенью (`angular_distance_deg`),
экспоненциальная дымка (`fog.density` 5e-5: 37 % пропускания на 20 км, дальние хребты синеют), glow, лёгкая коррекция цвета.
Камерам: `SkyEnvironment.setup_camera(cam)` ставит near/far из `world.json → rendering` (far 110 км).

## Использование
```gdscript
var terrain: Terrain = $Terrain          # location_id = "altai" грузится в _ready
atmosphere.set_ground(terrain.height_at, terrain.sun_exposure_at)
var site: Dictionary = terrain.get_start_sites()[0]   # {id, name, position, heading_deg, lat, lon}
glider.reset_on_ground(site.position, site.heading_deg)

# произвольная точка (FR-17): асинхронно, затем сигнал loaded
terrain.load_location_latlon(43.25, 42.45, 40.0)
await terrain.loaded

# карта выбора места
var picker := MapPicker.new()
picker.point_picked.connect(func(lat, lon): terrain.load_location_latlon(lat, lon))
```

## Как добавить локацию
1. Скопировать `configs/locations/altai.json` в `configs/locations/<id>.json`, поменять `name`, `center_lat/lon`,
   `data_dir` (`res://data/terrain/<id>`), при желании размеры слоёв (сторона/шаг должны давать целое число `chunk_cells`).
2. `uv run --with numpy --with pillow --with tifffile --with imagecodecs python tools/terrain/fetch_dem.py <id> --preview=/tmp`
   — скачает Copernicus/Terrarium (кеш `~/.cache/deltaplan_terrain`), сохранит слои, маски рек и `meta.json`
   (≈ 30 с; отмывки для проверки — в `/tmp`).
3. Вписать `start_sites` (lat, lon, `heading_deg` — курс разбега вниз по склону). Проверка: тесты
   `tests/terrain` (для другой локации поменять `LOCATION`) — старт на склоне 8–35°, вниз по курсу.
4. `godot --path . res://scenes/terrain/terrain_preview.tscn -- --site=<id старта>` — посмотреть.
5. Внести данные в `ASSETS.md`.

## Превью и замеры
```
godot --path . res://scenes/terrain/terrain_preview.tscn -- [--site=<id>] [--agl=м] [--yaw=°] [--pitch=°]
      [--shot=file.png] [--bench] [--no-trees] [--no-shadows] [--latlon=lat,lon]
```
WASD/QE/Shift — полёт камеры, правая кнопка — обзор. `--bench` печатает FPS и GPU-время.
RTX 4070 SUPER, 1080p, Forward+: 1.5 мс GPU на кадр со всем (деревья, тени); без деревьев и теней — 0.3 мс.
Для встроенной графики (NFR-1): если не хватает — `trees.radius_m` 300, `trees.cast_shadows` false,
`sun.shadow_max_distance_m` 1500; в Compatibility-рендере всё работает (проверено на llvmpipe).

## Заменяемые ассеты
Текстуры поверхностей — пути в `configs/world.json → terrain_textures` (пусто — процедурно; нет файла — предупреждение
и процедурно). Реки — PNG-маски, которые можно заменить картой воды из OSM. Деревья пока процедурные
(«токарные» кроны в шейдере); замена на модели — отдельным этапом.
