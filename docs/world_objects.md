# Объекты мира (world_objects)

VR-6, VR-7, VR-9, VR-10, VR-12, VR-13, NFR-1, NFR-2. Ветроуказатели и ленточки по локальному ветру модели,
посадочные площадки, дороги, здания и ЛЭП из OpenStreetMap, столкновения с проводами и препятствиями.

## Что где
| Файл | Что делает |
|---|---|
| `scripts/world_objects/world_objects.gd` (`WorldObjects`, Node3D) | главный компонент: `setup(terrain, atmosphere)`, анимация ветроуказателей, `wire_hit` / `obstacle_hit`, `get_landing_sites` |
| `wind_cloth_model.gd` (`WindClothModel`) | поведение конуса/ленты по воздуху: поворот (пружина с демпфером, жёсткость ∝ напору), наполнение от скорости, наклон от вертикального потока, болтание от СКО порывов. Без нод |
| `wind_indicator.gd` (`WindIndicator`) + `wind_cloth.gdshader` | ветроуказатель/вешка: визуал из сцены, поворот ноды `Pivot`, ткань гнёт вершинный шейдер (провисание, сужение пустого хвоста, бегущая волна) |
| `landing_site.gd` (`LandingSite`) | посадка: скошенное поле по рельефу с полосами покоса, лесополосы, забор, коллизии |
| `osm_data.gd` (`OsmData`) | загрузка `data/osm/<id>.json`, пересчёт координат, если центр рельефа другой |
| `osm_layer.gd` (`OsmLayer`) | отрисовка OSM: дороги, здания, опоры и провода, заборы у посадок (дороги и здания считаются в пуле потоков) |
| `road_mesher.gd`, `building_placer.gd`, `power_line_planner.gd` | чистые построители: ленты дорог по тайлам, коробки зданий для MultiMesh, опоры и цепные линии |
| `obstacle_index.gd` (`ObstacleIndex`) | сетка препятствий: капсулы (провода), цилиндры (деревья, опоры), повёрнутые коробки (здания, заборы) |
| `draped.gdshader` | дороги и покос: сдвиг к камере против утопания в грубом LOD рельефа, растушёвка края дизерингом |
| `wire.gdshader` | провода: лента к камере не тоньше пикселя, прозрачность = доля покрытия пикселя → тают с расстоянием |
| `world_tiles.gd` (`WorldTiles`) | тайлы, MultiMesh с дальностью видимости, загрузка меша из модели с заглушкой |
| `scenes/world_objects/world_objects.tscn` | компонент для главной сцены |
| `scenes/world_objects/{windsock,streamer}_visual.tscn` | обёртки визуала (маркер `Pivot`, меш `Sock`/`Ribbon`) |
| `scenes/world_objects/world_objects_preview.tscn` | тестовая сцена с рельефом и атмосферой |
| `tools/osm/fetch_osm.py` | выгрузка OSM (Overpass API) → `data/osm/<id>.json` |
| `tools/blender/world_objects/build_world_objects.py` | модели: ветроуказатель, вешка с лентой, пролёт забора, опора 110 кВ, столб 10 кВ |
| `configs/world_objects.json` | все параметры, посадки по локациям, пресеты качества |

## Подключение (главная сцена)
```gdscript
var world_objects: WorldObjects = preload("res://scenes/world_objects/world_objects.tscn").instantiate()
add_child(world_objects)                      # сначала в дерево (нужна камера для «активных»)
await terrain.loaded                           # или сразу, если рельеф уже загружен
world_objects.setup(terrain, atmosphere)       # atmosphere может быть null — тогда штиль
# столкновения (в _physics_process интегратора, отрезок пути за шаг):
if world_objects.wire_hit(prev_pos, glider.global_position):
    ...                                         # провод ЛЭП
var hit := world_objects.obstacle_hit(prev_pos, glider.global_position)  # {kind, point} или {}
# kind: wire | tower | building | tree | fence
var landings := world_objects.get_landing_sites()  # [{id, name, position, axis_deg, length_m, width_m}]
```
- Рельеф передаёт: `location_id`, `get_start_sites()`, `get_landing_sites()` (если есть), `height_at`,
  `latlon_to_local`, `center_lat/lon`. Атмосфера — `air_velocity_at`.
- Смена локации: снова `setup(...)` (старые объекты удаляются). Сигнал `built` — всё построено.
- Для рантайм-точки (`load_location_latlon`, `location_id == ""`) OSM-данных нет: ставятся только
  ветроуказатели на стартах. Выгрузка OSM в игре — задел (см. questions.md).
- Проверять столкновение стоит для центра и концов крыла; препятствия без физического движка (`height_at`
  как у полёта), запрос ~мкс (сетка 64 м).

## Ветроуказатели (VR-7, VR-0, VR-20)
- На каждом старте — конус на мачте 4 м (сбоку от полосы разбега, `windsock.launch_offset`) и 4 вешки
  с красно-белой лентой по краям полосы (`streamers.offsets`). На каждой посадке — конус с мачтой 6 м.
- Воздух берётся **у вертлюга** (`air_velocity_at` — с порывами, ротором, термиками), 30 Гц, только у
  ветроуказателей ближе `active_radius_m` к камере. Поэтому в роторе соседние конусы показывают разное,
  а в термике конус чуть задирается (`max_pitch_deg`).
- Наполнение `fill = ((v − lift)/(full − lift))^curve`: конус висит ниже 4 км/ч, горизонтален с 28 км/ч
  (авиационный стандарт — 15 уз); лента — с 12 км/ч. Инерция — `speed_tau_s`.
- Поворот — флюгер: жёсткость `yaw_stiffness · v`, демпфирование — в слабый ветер конус лениво
  дрейфует, в сильный быстро встаёт и слегка качается.
- Болтание: амплитуда хвоста `flutter_base + flutter_per_gust · σ(v)` (σ — СКО скорости за
  `gust_window_s`), частота ∝ скорости.

**Сверка с фото** (коллаж — `scratchpad/windsock_vs_photos.jpg`, ракурс `--view=sock`):
1. [Старт парапланов, Мерида](https://commons.wikimedia.org/wiki/File:7_-_parapente_tierra_negra_-_merida.JPG)
   (CC BY-SA 3.0) — слабый ветер: конус наполнен наполовину, опущен ~30°;
2. [Конус на мачте, средний ветер](https://commons.wikimedia.org/wiki/File:Windsock.jpg) (CC BY-SA 4.0) —
   провис ~35°, хвост ниже обруча;
3. [Колдун на аэродроме](https://commons.wikimedia.org/wiki/File:%D0%98_%D0%B5%D1%89%D0%B5_%D1%82%D0%B0%D0%BC_%D0%B5%D1%81%D1%82%D1%8C_%22%D0%9A%D0%BE%D0%BB%D0%B4%D1%83%D0%BD%22_-_panoramio.jpg)
   (CC BY 3.0) — сильный ветер: горизонтально, прямо.

✔ пропорции мачты и конуса, полосы, провис в слабый ветер, горизонталь в сильный.
✘ в игре на средней скорости конус изогнут дугой, на фото — чаще прямой и наклонён целиком
(ткань натянута давлением); подправить — меньше `droop_tip_deg` относительно `droop_root_deg`.
✘ у реального конуса обруч на вертлюге, в модели — рычаг без растяжек (видно только вблизи).

## Посадочные площадки (VR-12)
Данные — `configs/world_objects.json → landing.sites.<id локации>` (папка `configs/locations/` не наша):
`id, name, lat, lon, length_m, width_m, axis_deg, grass_color, windsock_at, trees[], fences[]`.
Если у рельефа есть `landing_sites` (terrain2 добавил их в `configs/locations/*.json`), запись с тем же
`id` берёт оттуда lat/lon; площадки рельефа без записи строятся с `landing.defaults` (ось — вдоль
горизонтали склона). Скошенное поле — меш по рельефу с полосами покоса (`draped.gdshader`),
вокруг — лесополосы (модели `assets/models/trees/`, масштаб по высоте), забор из пролётов, заборы OSM
ближе `osm_fence_radius_m`, ЛЭП из OSM; всё — препятствия.

| Локация | Площадка | Как выбрана |
|---|---|---|
| altai | поле у Озёрного, 51.83476, 85.81696, 300×200 м, ось 98° | точных координат официальной посадки у Синюхи нет в открытых источниках; взято реальное поле OSM `landuse=farmland` (6 га, уклон ≤ 2°) в 3 км к ЗСЗ от западного старта; в ~120 м севернее — реальная ЛЭП 110 кВ |
| ongudai | ongudai_fields (точка terrain2), 300×150 м, ось 20° | ровный луг (1,5°) в долине севернее Онгудая, по долине против южного ветра; ЛЭП 110/10 кВ в ~500 м и заборы — из OSM |
| askarovo | idyash_west 300×160 м, ось 110°; biyagoda_east_field 250×140 м, ось 94° | точки terrain2 (уклон 0,6° и 2,5°), ось по ветру соответствующего старта, берёзовые колки |

## OSM (VR-9, VR-10)
**Данные** `data/osm/<id>.json` (© OpenStreetMap contributors, ODbL — строка в ASSETS.md и в файле):
```
{attribution, location, center_lat, center_lon, bbox_latlon,
 roads:     [{t: класс highway, p: [x, z, x, z…]}],
 buildings: [[x, z, w, l, угол_град, высота_стен_м, крыша 0 — двускатная / 1 — плоская]],
 power:     [{k: line|minor_line, v: кВ, c: проводов, p: [...], s: [1 — опора в узле]}],
 water:     {rivers: [{t, n, p}], lakes: [{n, p}]},
 places:    [{n, t, x, z, pop}],
 landuse:   {fields: [{t, p}], fences: [{t, p}]}}
```
Координаты — мир игры (x — восток, z — юг, м) относительно центра локации, та же проекция, что `TerrainGeo`.
Здание — минимальный описанный прямоугольник контура; высота — `height` / `building:levels` / этажность по типу.

**Отрисовка:**
- дороги — ленты по рельефу (шаг 12 м главные, 20 м прочие), видны 25 км (главные) / 4 км (прочие);
- здания — коробки стен + призма крыши, MultiMesh по тайлам 1 км, видны 7 км;
- ЛЭП — решётчатые опоры 110 кВ / столбы 10 кВ по узлам (длинные пролёты делятся), провода — парабола
  с провисанием 3 % пролёта; провод рисуется реальной толщины 2 см, но не тоньше пикселя с прозрачностью
  по покрытию: вблизи — линия, на 100–200 м — едва заметная нить, дальше 500 м не рисуется (как в жизни);
- **реки и озёра не рисуются**: вода уже в раскраске рельефа (маски terrain). Данные OSM о воде лежат в файле —
  terrain может заменить ими маски рек из стока;
- населённые пункты — только данные (`places`) для карты прибора/меню.

## Как добавить локацию
1. terrain создаёт `configs/locations/<id>.json` и `data/terrain/<id>/` (центр, старты, `landing_sites`).
2. `uv run python tools/osm/fetch_osm.py <id>` — квадрат = детальный слой рельефа; кеш сырых ответов
   `~/.cache/deltaplan_osm/` (`--refresh` — заново). Overpass часто отвечает 504 — скрипт перебирает зеркала
   из `osm.overpass_urls`; повторный запуск докачивает только недостающие слои.
3. Посадки: посмотреть поле (уклон, ЛЭП, заборы) — например картой высот + OSM, как в разделе выше;
   записать `landing.sites.<id>` в `configs/world_objects.json` (ось, размер, деревья, цвет травы под местность).
4. `godot --path . res://scenes/world_objects/world_objects_preview.tscn -- --location=<id> --view=landing`.
5. Строка в ASSETS.md (данные OSM локации).

## Превью, замеры, тесты
```
godot --path . res://scenes/world_objects/world_objects_preview.tscn -- [--location=<id>]
      [--view=start|landing|village|wires|sock] [--wind=км/ч] [--from=°] [--weather=…] [--time=с]
      [--shot=file.png] [--bench]
```
1–5 — ракурсы, WASD/QE — полёт, ПКМ — обзор. Скриншоты — Forward+ (`DISPLAY=:0`) и Compatibility
(`xvfb-run … --rendering-method gl_compatibility`) — оба работают.

**GPU** (RTX 4070 SUPER, Forward+, `--bench`: кадр с объектами минус без): старт 0,16 мс, посадка 0,11 мс,
посёлок с 300 м 0,10 мс — бюджет 1 мс с запасом. Для встроенной графики — `quality: "low"` (короче дальности,
без теней у зданий, опор и посадки, 15 Гц ветроуказатели).
**Загрузка** (`build_time_s`): Алтай 1,5–2,6 с (27 тыс. зданий, 2000 км дорог, 5400 проводов), Онгудай
2,3 с, Аскарово 2,2 с — дороги и здания считаются в пуле потоков параллельно с ЛЭП (`threaded_build`).

`godot --headless --path . res://tests/run_tests.tscn -- --filter=world_objects` — данные OSM грузятся и
пересчитываются, конус поворачивается по ветру и за сменой ветра, провисает в слабый ветер, болтается в
порывах, задирается в восходящем потоке; нода Pivot смотрит по ветру; ветроуказатели и опоры на земле,
здания от земли; посадка ровная, вокруг препятствия; цепная линия и столкновение с проводом (синтетика и
реальные ЛЭП); время сборки.

## Заменяемые ассеты
Пути — в конфиге: `windsock.scene_path`, `streamers.scene_path` (обёртки с `Pivot` + `Sock`/`Ribbon`, ткань
вдоль −Z; длина — `sock_length_m`/`ribbon_length_m`, отступ обруча — `root_offset_m`),
`landing.tree_scene_path`/`pine_scene_path`/`fence_scene_path`, `power.tower_scene_path`/`pole_scene_path`
(точки подвеса проводов — `tower_arms_m`/`pole_arms_m`). Нет файла — процедурная заглушка и предупреждение.
Скриншоты моделей — `docs/models/screenshots/world/<модель>/{bottom,front,side,iso45}.png`
(`blender --background --python tools/blender/render_views.py -- world/<модель> docs/models/screenshots/world/<модель> bottom,front,side,iso45`).
