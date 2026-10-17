---
type: "guide"
status: "active"
module: "world"
area: "world"
updated: "2026-10-17"
summary: "WorldObjects: файлы, подключение к сцене, API; ветроуказатели, посадки, лагерь, посёлки, OSM-слой и пасхалки — в частях world-objects/."
related: ["docs/guide/world-objects/wind-landing.md", "docs/guide/world-objects/start-camp.md", "docs/guide/world-objects/villages-osm.md", "docs/guide/world-objects/easter-eggs.md", "docs/guide/world-objects/sea-ships.md", "docs/guide/terrain.md", "docs/guide/location-data.md", "docs/guide/osm-tiles.md"]
---
# Объекты мира (world_objects)

VR-6, VR-7, VR-9, VR-10, VR-12, VR-13, NFR-1, NFR-2. Компонент `WorldObjects` собирает всё, что стоит на земле рядом с пилотом: ветроуказатели и
ленточки по локальному воздуху модели, посадочные площадки, тропа и лагерь у старта, дома посёлков, столкновения с препятствиями.
Дома ставятся процедурно в пятнах застройки по карте покрова ESA WorldCover; настоящие дороги, дома, ЛЭП, мачты, ветряки, канатки и
вершины приходят из тайлов OSM (слой `OsmLayer`, раздел «OSM-слой» в [villages-osm.md](world-objects/villages-osm.md)); если тайлов нет, остаются процедурные дома и
остальное.

## Устройство по частям
| Часть | О чём |
|---|---|
| [world-objects/wind-landing.md](world-objects/wind-landing.md) | ветроуказатели (конус, вешки), посадочные площадки |
| [world-objects/start-camp.md](world-objects/start-camp.md) | тропа к старту, палатки, снаряжение и крылья, примятая трава, ткань, люди, костёр |
| [world-objects/villages-osm.md](world-objects/villages-osm.md) | просеки для деревьев, процедурные дома посёлков, OSM-слой из тайлов, деревья города и сёл |
| [world-objects/easter-eggs.md](world-objects/easter-eggs.md) | каркас пасхалок мира (на сайт не выкладывается) |


## Что где
| Файл | Что делает |
|---|---|
| `scripts/world_objects/world_objects.gd` (`WorldObjects`, Node3D) | главный компонент: `setup(terrain, atmosphere)`, анимация ветроуказателей, `obstacle_hit`, `get_landing_sites` |
| `wind_cloth_model.gd` (`WindClothModel`) | поведение конуса/ленты по воздуху: поворот (пружина с демпфером, жёсткость ∝ напору), наполнение от скорости, наклон от вертикального потока, болтание от СКО порывов. Без нод |
| `wind_indicator.gd` (`WindIndicator`) + `wind_cloth.gdshader` | ветроуказатель/вешка: визуал из сцены, поворот ноды `Pivot`, ткань гнёт вершинный шейдер (провисание, сужение пустого хвоста, бегущая волна) |
| `landing_site.gd` (`LandingSite`) | посадка: скошенное поле по рельефу с полосами покоса, лесополосы, коллизии |
| `village_placer.gd` (`VillagePlacer`) | дома посёлков: процедурно внутри пятен застройки (`BuiltPatches`), контракт N3, `configs/world_objects.json → villages`; пятна с домами OSM пропускает. Без нод |
| `village_layer.gd` (`VillageLayer`) | отрисовка домов: записи `VillagePlacer` → `BuildingPlacer` → MultiMesh по тайлам, препятствия `building` |
| `building_placer.gd` | чистый построитель: коробки стен и призмы крыш для MultiMesh |
| `start_tracks.gd` (`StartTracks`) | тропы к стартам: процедурная тропа вниз по склону (серпантин); меш — узкая грунтовая лента |
| `tent_camp.gd` (`TentCamp`) | лагерь палаток у старта: выбор ровного места, кучка палаток (тип, цвет, поворот), визуал 2 LOD. План — без нод |
| `start_gear.gd` (`StartGear`) | снаряжение у каждого старта: крылья на штанге, полусобранный аппарат, чехлы, рюкзаки, шлемы, бутылки; план — без нод, визуал — MultiMesh и `glider_<id>.glb` |
| `trample_mask.gd` (`TrampleMask`) | маска примятой травы R8 вокруг старта (палатки, тропинки, вещи, круг разбега, тропа); без нод |
| `camp_fabric.gd` (`CampFabric`) + `assets/shaders/camp/camp_fabric.gdshader` | общий шейдер ткани и материал на пресет (палатки, чехлы, парус, одежда людей) |
| `easter_eggs/people.gd` (`EggPeople`) | люди у лагеря: вблизи `camp_pilot.glb` со скелетом, вдали MultiMesh `camp_person.glb` |
| `campfire.gd` (`Campfire`) + `smoke_particles.gdshader`, `smoke_puff.gdshader`, `flame_puff.gdshader` | костёр в лагере: кольцо камней и поленья (процедурный меш), пламя и дым — GPUParticles3D, мерцающий свет; дым сносит локальный ветер |
| `obstacle_index.gd` (`ObstacleIndex`) | сетка препятствий: цилиндры (деревья), повёрнутые коробки (дома, палатки) |
| `draped.gdshader` | тропы и покос: сдвиг к камере против утопания в грубом LOD рельефа, растушёвка края дизерингом |
| `world_clearings.gd` (`WorldClearings`) | маска просек для деревьев рельефа: дома посёлков, посадки, тропы к стартам |
| `world_tiles.gd` (`WorldTiles`) | тайлы, MultiMesh с дальностью видимости, загрузка меша из модели с заглушкой |
| `osm_data.gd` (`OsmData`), `osm_layer.gd` (`OsmLayer`) | данные OSM места из тайлов (`osm_tiles.json` + кеш) и каркас слоя; части слоя — `scripts/world_objects/osm/`: `OsmRoads`, `OsmPilot`, `OsmBuildings`, `OsmTraffic`, `OsmWindTurbines`, `OsmCableCars`, `OsmSmoke`, `OsmChimneyPlumes`, `OsmCityGround`, `CityTrees` + `CityTreePlan`, `BuildingStyle`, `OsmTileReader`, `OsmGrid` |
| `easter_eggs/*.gd` (`EasterEggs`, `EggPlace`, …) | пасхалки — [world-objects/easter-eggs.md](world-objects/easter-eggs.md) |
| `scenes/world_objects/world_objects.tscn` | компонент для главной сцены |
| `scenes/world_objects/{windsock,streamer}_visual.tscn` | обёртки визуала (маркер `Pivot`, меш `Sock`/`Ribbon`) |
| `scenes/world_objects/world_objects_preview.tscn` | тестовая сцена с рельефом и атмосферой |
| `tools/blender/world_objects/build_world_objects.py` | модели: ветроуказатель, вешка с лентой |
| `tools/blender/build_start_gear.py`, `build_glider_kit.py`, `build_camp_person.py`, `build_camp_pilot.py` | модели лагеря → `assets/models/world/{start_gear,glider_kit,camp_person,camp_pilot}.glb` (см. `models.md`) |
| `tools/blender/build_tents.py` | палатки: купольная 2-местная, туннельная 3-местная, тент-навес → `assets/models/world/tents.glb` |
| `tools/shots/tents_shot.tscn` | кадры лагеря в игре (с земли, сбоку, вблизи, сверху) и всех моделей × цветов |
| `tools/shots/campfire_shot.tscn` | кадры костра с дымом: со старта, вблизи, с воздуха в 300 и 500 м (`--wind=`, `--hour=`) |
| `configs/world_objects.json` | все параметры, посадки по локациям, пресеты качества |
| `ship_placer.gd` (`ShipPlacer`), `ship_layer.gd` (`ShipLayer`) | суда на море — раздел «Суда» ниже |

## Подключение (главная сцена)
```gdscript
var world_objects: WorldObjects = preload("res://scenes/world_objects/world_objects.tscn").instantiate()
add_child(world_objects)                      # сначала в дерево (нужна камера для «активных»)
await terrain.loaded                           # или сразу, если рельеф уже загружен
world_objects.setup(terrain, atmosphere)       # atmosphere может быть null — тогда штиль
# столкновения (в _physics_process интегратора, отрезок пути за шаг):
var hit := world_objects.obstacle_hit(prev_pos, glider.global_position)  # {kind, point} или {}
# kind: building | tree | tent | gear | tower | wire
var landings := world_objects.get_landing_sites()  # [{id, name, position, axis_deg, length_m, width_m}]
```
- Рельеф передаёт: `location_id`, `get_start_sites()`, `get_landing_sites()` (если есть), `height_at`,
  `latlon_to_local`, `center_lat/lon`. Атмосфера — `air_velocity_at`.
- Смена локации: снова `setup(...)` (старые объекты удаляются). Сигнал `built` — всё построено.
- Для места точки (`location_id` — ключ кеша `pt_…`) процедурные дома берутся из пятен застройки `built_patches.json` папки места (нет покрова — их нет), OSM-слой — из `osm_tiles.json` той же папки (нет тайлов — слоя нет); ветроуказатели на стартах ставятся всегда.
- Проверять столкновение стоит для центра и концов крыла; препятствия без физического движка (`height_at`
  как у полёта), запрос ~мкс (сетка 64 м).

## Суда
Виды, LOD, ограничения, маска моря и уровень воды — [sea-ships.md](world-objects/sea-ships.md). Контракты S2–S4 (`docs/contracts/sea-ships.md`), параметры — `configs/sea_ships.json`.
- `ShipPlacer.ships_for(mask, center_lat, center_lon, params, height_fn)` — без нод, контракт S3 v3: на место 2–6 судов (`n_min`…`n_max`,
  по хешу клетки центра 0,05°) в полосе 3–15 км от берега (`shore_min_m`/`shore_max_m` по маске S2: v ∈ [31, 151]) и ≤ 30 км от центра
  (`center_max_m`). Кандидаты — мировые клетки 0,02° (`cell_deg`): из хеша `TreeCell.hash` точка, вид (`placement.types`, веса 1/1/1), курс,
  ранг; берутся N годных с наименьшим рангом, не ближе `min_sep_m` (1,5 км). В метры места — последним шагом, поэтому одна точка мира из
  разных мест даёт то же судно; набор зависит от места, не от пилота.
- `WorldObjects.build` → `_start_ships`: `SeaMask.load_for` (файл `far_sea.webp` или счёт 1–3 с для мест из `res://`) и расстановка — в
  `WorkerThreadPool`, узлы — в главном потоке (`_ships_done`, сигнал `ships_ready`). Нет моря — ни одного узла, без `_process`.
- `ShipLayer` — на судно по `MeshInstance3D` на каждый LOD модели `assets/models/ships/ship_<вид>.glb` (`<вид>_LOD0..2`) с
  `visibility_range_begin/end` (`render.lod_m`: 6 и 25 км, LOD2 — до `world.json → rendering.camera_far_m`); движок сам отсекает по дальности и
  пирамиде видимости. MultiMesh не взят: рамка MultiMesh — весь квадрат, отсечения по судну нет, а судов ≤ 6 на место.
  Ватерлиния — `y` записи: высота рельефа в точке (`height_fn` = `Terrain.height_at`; стадия `sea` выравнивает море far до уровня L, у океана 0 м); материал — `StandardMaterial3D` с вершинными цветами (импортёр glTF их как альбедо не включает). Тень — только LOD0
  (`render.cast_shadow_lod0`, пресет «Низкое» — без теней). Вид без `.glb` пропускается (вес вида в `placement.types` — 0, пока модели нет).
- Тесты: `--filter=ship_placer`, `--filter=ship_layer`, `--filter=sea_ships_contracts`.

## Как добавить локацию
1. Создать `configs/locations/<id>.json` и собрать место `build_location.gd -- --id <id>` (рельеф, реки и покров
   одним сборщиком — `docs/guide/terrain.md`, `docs/guide/location-data.md`); встроенное место собирается в `user://locations/<id>` при первом выборе, в репозитории данных места нет.
2. Посадки: посмотреть поле (уклон, дома рядом) — картой высот и покрова;
   записать `landing.sites.<id>` в `configs/world_objects.json` (ось, размер, деревья, цвет травы под местность).
3. `godot --path . res://scenes/world_objects/world_objects_preview.tscn -- --location=<id> --view=landing`.
4. Строка в ASSETS.md, если у места появились свои данные.

## Превью, замеры, тесты
```
godot --path . res://scenes/world_objects/world_objects_preview.tscn -- [--location=<id>]
      [--view=start|landing|sock|track] [--wind=км/ч] [--from=°] [--weather=weak|medium|strong] [--time=с] [--mask=out.png]
      [--shot=file.png] [--bench]
```
1–5 — ракурсы, WASD/QE — полёт, ПКМ — обзор. Скриншоты — Forward+ (`DISPLAY=:0`) и Compatibility
(`xvfb-run … --rendering-method gl_compatibility`) — оба работают.

**GPU** (RTX 4070 SUPER, Forward+, `--bench`: кадр с объектами минус без): старт 0,16 мс, посадка 0,11 мс,
посёлок с 300 м 0,10 мс — бюджет 1 мс с запасом. Для встроенной графики — `quality: "low"` (короче дальности,
без теней у зданий, опор и посадки, 15 Гц ветроуказатели).
**Загрузка** (`build_time_s`): Аскарово 1,66 с после NO-10 (36,6 тыс. домов; 0,89 с при NO-2 и 14 тыс.), план домов считается один раз (кеш `VillagePlacer`).

`godot --headless --path . res://tests/run_tests.tscn -- --filter=world_objects` — пятна застройки грузятся (`test_villages`), конус поворачивается по ветру и за сменой ветра, провисает в слабый ветер, болтается в
порывах, задирается в восходящем потоке; нода Pivot смотрит по ветру; ветроуказатели и опоры на земле,
дома от земли; посадка ровная, вокруг препятствия; время сборки; палатки (`test_tents.gd`): число = 1 + боты, детерминированность, на ровном
поле встают все, на крутом склоне — ни одной, на Онгудае и Аскарово — не впереди старта, не в коридоре
разбега и на местах ботов, не на тропе, не в воде/лесу, уклон ≤ 8°, зазоры, палатка — препятствие; кольцо 30–50 м и ступени (`start_camp_contracts_k1`), снаряжение (`test_start_gear.gd`, `start_camp_contracts_k2`), трава (`test_grass_trample`, `start_camp_contracts_k6`), ткань (`test_camp_fabric`, `k5`), люди (`test_egg_people`, `k4`).

## Заменяемые ассеты
Пути — в конфиге: `windsock.scene_path`, `streamers.scene_path` (обёртки с `Pivot` + `Sock`/`Ribbon`, ткань
вдоль −Z; длина — `sock_length_m`/`ribbon_length_m`, отступ обруча — `root_offset_m`),
`landing.tree_scene_path`/`pine_scene_path`. Нет файла — процедурная заглушка и предупреждение.
Скриншоты моделей — `docs/models/screenshots/world/<модель>/{bottom,front,side,iso45}.png`
(`blender --background --python tools/blender/render_views.py -- world/<модель> docs/models/screenshots/world/<модель> bottom,front,side,iso45`).
