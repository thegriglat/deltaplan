# Рельеф и мир

FR-17…FR-20, VR-3, VR-4, VR-0, NFR-1, NFR-2. Исследование источников — [research/terrain_sources.md](research/terrain_sources.md).

## Что где
| Файл | Что делает |
|---|---|
| `scripts/terrain/terrain.gd` (`Terrain`, группа `"terrain"`) | нода рельефа: загрузка локации, контракт `height_at / normal_at / get_start_sites / sun_exposure_at`, `surface_at / thermal_source_strength_at / get_landing_sites` |
| `scripts/terrain/surface_layer.gd` (`SurfaceLayer`) | карта поверхности (классы земного покрова) на сетке, `class_at`, текстура R8 |
| `scripts/terrain/surface_classifier.gd` (`SurfaceClassifier`) | запасная процедурная карта (нет сети) по высоте/уклону/экспозиции/шуму |
| `scripts/terrain/cog_reader.gd` (`CogReader`), `worldcover_loader.gd` (`WorldCoverLoader`) | разбор COG GeoTIFF и рантайм-загрузка WorldCover HTTP range-запросами, кеш `user://terrain_cache/worldcover` |
| `scripts/terrain/tree_placer.gd` (`TreePlacer`), `terrain_tree_models.gd` (`TerrainTreeModels`) | деревья-модели 5 пород × 3 LOD (MultiMesh), расстановка в рабочем потоке |
| `scripts/terrain/height_layer.gd` (`HeightLayer`) | сетка высот, билинейная выборка (RefCounted, тестируется headless) |
| `scripts/terrain/geo.gd` (`TerrainGeo`) | lat/lon ↔ мир, направление солнца, вектор курса |
| `scripts/terrain/terrain_renderer.gd` (`TerrainRenderer`) | чанки + LOD, материалы, текстуры поверхностей |
| `scripts/terrain/terrain.gdshader` + `terrain_common.gdshaderinc` | высоты в вершинном шейдере, раскраска (трава, лес, поля, скалы, снег, реки) |
| `scripts/terrain/terrain_trees.gd` + `trees.gdshader` (`TerrainTrees`) | запасные процедурные кроны (если нет моделей) |
| `scripts/terrain/terrarium_loader.gd` (`TerrariumLoader`) | рантайм-загрузка рельефа по lat/lon (FR-17), кеш `user://terrain_cache` |
| `scripts/terrain/map_picker.gd` + `map_hillshade.gdshader` (`MapPicker`) | карта выбора точки: отмывка из Terrarium, щелчок / ввод координат → `point_picked(lat, lon)` |
| `scripts/world/sky_environment.gd` (`SkyEnvironment`), `haze.gdshader`, `scenes/world/environment.tscn` | небо, солнце с мягкими тенями, голубая дымка, мутный слой под инверсией (VR-3), glow |
| `scenes/terrain/terrain_preview.tscn`, `map_picker_preview.tscn` | отдельный запуск модуля |
| `tools/terrain/fetch_dem.py`, `rivers.py`, `fetch_landcover.py`, `cog.py` | подготовка данных встроенной локации (высоты, реки, карта поверхности) |
| `configs/locations/<id>.json` | локация: центр, слои DEM, LOD, старты, посадки, реки, карта поверхности, переопределения вида и пород деревьев |
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

**Карта поверхности (VR-4, VR-0).** Классы: 1 лес, 2 луг/трава, 3 пашня/поля, 4 кустарник, 5 скалы/голый грунт,
6 вода, 7 застройка, 8 снег; 0 — нет данных. Источник — ESA WorldCover 2021 (10 м, CC-BY 4.0), `fetch_landcover.py`
читает только нужные тайлы COG (HTTP range, без GDAL), класс узла — мода 3×3 подвыборок; перевод кодов WorldCover —
`world.json → surface.worldcover.classes`. Файлы `<слой>_surface.png` (8 бит, значение = класс, та же сетка, что у высот,
не импортируются Godot: `importer="keep"`) + `surface.json`. Данные: ~0,5 МБ на локацию.
Из **этой одной карты** берутся цвет земли (шейдер), деревья (только на «лесе») и сила источников термиков.
`surface_at(x, z)` — класс ближайшего узла; луг/поле/кустарник круче `terrain_look.rock_slope_deg` → скалы (как в шейдере).
Поляны у стартов (`start_clearing_radius_m`) вписаны прямо в карту (лес/кустарник → луг).
`thermal_source_strength_at(x, z)` = clamp(`class_strength[класс]` · `exposure_gain` · освещённость^`exposure_power`
· (1 + `edge_boost` · близость к границе), 0, 1) — `world.json → surface.thermal`: поле/скалы/застройка сильные, лес 0,45,
вода 0,05; границы поле–лес, луг–лес, пашня–луг — триггеры (полное усиление ближе 50 м, до 150 м спадает).
Семантика та же, что у `sun_fn` атмосферы (0..1, ниже `atmosphere.thermal.sun_min` термик не рождается): ровное поле ≈ 0,87,
поле у опушки 1, лес ≈ 0,38, вода 0.
**Рантайм (`load_location_latlon`)**: `WorldCoverLoader` берёт обзорный уровень COG с пикселем ≤ шага карты
(шаг = шаг высот × `surface.runtime.cell_factor`), качает 1024² тайлы параллельно (≈ 30–150 КБ каждый), выборка — в потоке.
Нет сети/данных → `SurfaceClassifier` (высота, уклон, экспозиция, шум, маска рек) — та же форма карты, путь дальше общий.

**Раскраска** (FR-19) по карте поверхности: доли классов в точке — билинейно по 4 узлам карты, обрезка по уровню 0,5 (граница — плавная кривая, не «лесенка»),
сдвиг порога шумом (`surface_edge_noise`, `surface_edge_sharpness`). Внутри класса — рисунок: пашня — прямоугольные участки
разного цвета, луг — сухая трава на южных склонах и пятнами, лес — хвойные/лиственные пятнами (больше хвойных на северных),
застройка — кварталы 18 м, скалы — по уклону (кроме леса), вода — класс «вода» с блеском. Вблизи — шум детализации, рельеф крон,
CC0-текстуры травы и скал (их рисунок, цвет остаётся процедурным — без шва вдали). Вокруг стартов — поляны.
**Деревья** (`TerrainTreeModels`): 5 пород (`assets/models/trees/tree_<порода>.glb`, пути — `world.json → trees.models`)
× 3 LOD (до 60 м — LOD0, до 180 м — LOD1, до `radius_m` — крест-импостор LOD2), по MultiMesh на породу и LOD.
`TreePlacer` раз в `rebuild_step_m` пересчитывает расстановку в рабочем потоке: клетка `spacing_m`, дерево только на классе
«лес», порода — по высотному поясу и экспозиции (`trees.species`: берёза и лиственница ниже, кедр и ель выше, ель на северных,
сосна на южных сухих склонах; локация переопределяет веса — в Онгудае лиственница ×4, на Биягоде сосна и берёза).
Всё — хешем клетки, дерево не «прыгает». Выше `max_agl_m` деревья не рисуются. Утоплены на `sink_fraction` (DSM с кронами).
Нет моделей → процедурные кроны `TerrainTrees` (как раньше).

**Мир.** `SkyEnvironment`: ProceduralSky, солнце с 4 каскадами теней (3 км) и полутенью (`angular_distance_deg`),
голубая дымка чистого воздуха (туман Godot, `fog.density` 2,5e-5: дальние хребты синеют), glow, лёгкая коррекция цвета.
**Дымка и инверсия (VR-3)** — `haze.gdshader`, полноэкранный квад поверх сцены (Forward+ и Compatibility): по глубине кадра
восстанавливается точка, оптическая толщина слоя считается аналитически вдоль луча (плотность постоянна до верха слоя,
линейный переход `top_transition_m`). Под верхом мутно (видимость `haze.visibility_km` = 60 км, вместе с голубой дымкой ≈ 50 км),
выше — чисто и сине; сверху у горизонта — резкая белёсая граница. Верх = `set_inversion_height_msl(h)` + `top_margin_m`
(интегратор передаёт `Atmosphere.get_cloudbase_msl()`), до вызова — `default_top_msl_m`.
Камерам: `SkyEnvironment.setup_camera(cam)` ставит near/far из `world.json → rendering` (far 110 км).

## Использование
```gdscript
var terrain: Terrain = $Terrain          # location_id = "altai" грузится в _ready
atmosphere.set_ground(terrain.height_at, terrain.thermal_source_strength_at)  # VR-4: источники из карты
sky.set_inversion_height_msl(atmosphere.get_cloudbase_msl())                  # VR-3: верх дымки
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
3. `uv run --with numpy --with pillow python tools/terrain/fetch_landcover.py <id>` — карта поверхности WorldCover
   (раздел `surface` локации: уровень COG и подвыборки по слоям; ≈ 1–3 мин, кеш `~/.cache/deltaplan_terrain/cog`).
4. Вписать `start_sites` (lat, lon, `heading_deg` — курс разбега вниз по склону, 1–3 старта) и `landing_sites`.
   Проверка: `tests/terrain/test_locations.gd` (добавить id в `LOCATIONS`) — старт на склоне 8–35°, вниз по курсу, не в лесу;
   посадка пологая, не лес и не вода. Бюджет данных — ≤ 15 МБ на локацию.
5. `godot --path . res://scenes/terrain/terrain_preview.tscn -- --location=<id> --site=<id старта>` — посмотреть.
6. Внести данные в `ASSETS.md`.

## Локации
| id | Что | Старты |
|---|---|---|
| `ongudai` | Алтай, долина Урсула у Онгудая, хребет с перевалом Каянча (полёты с 1980-х) | южный склон у Онгудайского ретранслятора, 1870 м, 151° |
| `askarovo` | Башкирия, хребет Биягода у Идяш-Кускарово (дельтадром, ЧР-2025) | запад у верхнего лагеря 294°, восток 94°, южная вершина 285° |
| `ekaterinburg` | Екатеринбург: Уктус, Шарташ (дельтаклуб «Ламинар», место — допущение) | западный склон Уктусских гор, 291° |
| `altai` | Манжерок, Малая Синюха (дополнительная) | 3 старта |
Источники и допущения — `_sources_doc` в конфиге локации и `questions.md → Рельеф 2`.

## Превью и замеры
```
godot --path . res://scenes/terrain/terrain_preview.tscn -- [--site=<id>] [--agl=м] [--yaw=°] [--pitch=°]
      [--shot=file.png] [--bench] [--no-trees] [--no-shadows] [--latlon=lat,lon] [--location=id]
      [--inversion=м] [--no-haze]
```
WASD/QE/Shift — полёт камеры, правая кнопка — обзор. `--bench` печатает FPS и GPU-время.
RTX 4070 SUPER, 1080p, Forward+: 1.5 мс GPU на кадр со всем (деревья-модели, тени, дымка); деревья — ≈ 0.25 мс
(в лесу у Синюхи: 1.47 мс с деревьями, 1.24 мс без); без деревьев и теней — 0.3 мс.
Для встроенной графики (NFR-1): если не хватает — `trees.radius_m` 300, `trees.cast_shadows` false,
`sun.shadow_max_distance_m` 1500; в Compatibility-рендере всё работает (проверено на llvmpipe).

## Заменяемые ассеты
Модели деревьев — `world.json → trees.models` (нет файла → процедурные кроны). Карта поверхности — PNG, можно
заменить любой другой классификацией (OSM landuse, свой рисунок) с теми же классами.
Текстуры поверхностей — пути в `configs/world.json → terrain_textures` (пусто — процедурно; нет файла — предупреждение
и процедурно). Реки (маски `rivers.py`) нужны только запасной карте; при карте WorldCover вода — её класс «вода».
