---
type: "guide"
status: "active"
module: "world"
updated: "2026-10-10"
summary: "Объекты мира (world_objects): ветроуказатели, посадки, процедурные дома посёлков в пятнах застройки WorldCover, тропы к стартам, лагерь, костёр, просеки, пасхалки. Без OSM: нет дорог, ЛЭП, заборов, полей и имён посёлков."
related: []
---
# Объекты мира (world_objects)

VR-6, VR-7, VR-9, VR-10, VR-12, VR-13, NFR-1, NFR-2. Ветроуказатели и ленточки по локальному ветру модели,
посадочные площадки, дома посёлков, столкновения с препятствиями. Данных OpenStreetMap в игре нет (модуль no-osm): нет
дорог, ЛЭП, заборов, зданий OSM, полей и имён посёлков; дома ставятся процедурно в пятнах застройки по карте покрова
ESA WorldCover (см. «Посёлки»).

## Что где
| Файл | Что делает |
|---|---|
| `scripts/world_objects/world_objects.gd` (`WorldObjects`, Node3D) | главный компонент: `setup(terrain, atmosphere)`, анимация ветроуказателей, `obstacle_hit`, `get_landing_sites` |
| `wind_cloth_model.gd` (`WindClothModel`) | поведение конуса/ленты по воздуху: поворот (пружина с демпфером, жёсткость ∝ напору), наполнение от скорости, наклон от вертикального потока, болтание от СКО порывов. Без нод |
| `wind_indicator.gd` (`WindIndicator`) + `wind_cloth.gdshader` | ветроуказатель/вешка: визуал из сцены, поворот ноды `Pivot`, ткань гнёт вершинный шейдер (провисание, сужение пустого хвоста, бегущая волна) |
| `landing_site.gd` (`LandingSite`) | посадка: скошенное поле по рельефу с полосами покоса, лесополосы, коллизии |
| `village_placer.gd` (`VillagePlacer`) | дома посёлков: процедурно внутри пятен застройки (`BuiltPatches`), контракт N3, `configs/world_objects.json → villages`. Без нод |
| `village_layer.gd` (`VillageLayer`) | отрисовка домов: записи `VillagePlacer` → `BuildingPlacer` → MultiMesh по тайлам, препятствия `building` |
| `building_placer.gd` | чистый построитель: коробки стен и призмы крыш для MultiMesh |
| `start_tracks.gd` (`StartTracks`) | тропы к стартам: процедурная тропа вниз по склону (серпантин); меш — узкая грунтовая лента |
| `tent_camp.gd` (`TentCamp`) | лагерь палаток у старта: выбор ровного места, кучка палаток (тип, цвет, поворот), визуал 2 LOD. План — без нод |
| `campfire.gd` (`Campfire`) + `smoke_particles.gdshader`, `smoke_puff.gdshader`, `flame_puff.gdshader` | костёр в лагере: кольцо камней и поленья (процедурный меш), пламя и дым — GPUParticles3D, мерцающий свет; дым сносит локальный ветер |
| `obstacle_index.gd` (`ObstacleIndex`) | сетка препятствий: цилиндры (деревья), повёрнутые коробки (дома, палатки) |
| `draped.gdshader` | тропы и покос: сдвиг к камере против утопания в грубом LOD рельефа, растушёвка края дизерингом |
| `world_clearings.gd` (`WorldClearings`) | маска просек для деревьев рельефа: дома посёлков, посадки, тропы к стартам |
| `world_tiles.gd` (`WorldTiles`) | тайлы, MultiMesh с дальностью видимости, загрузка меша из модели с заглушкой |
| `scenes/world_objects/world_objects.tscn` | компонент для главной сцены |
| `scenes/world_objects/{windsock,streamer}_visual.tscn` | обёртки визуала (маркер `Pivot`, меш `Sock`/`Ribbon`) |
| `scenes/world_objects/world_objects_preview.tscn` | тестовая сцена с рельефом и атмосферой |
| `tools/blender/world_objects/build_world_objects.py` | модели: ветроуказатель, вешка с лентой |
| `tools/blender/build_tents.py` | палатки: купольная 2-местная, туннельная 3-местная, тент-навес → `assets/models/world/tents.glb` |
| `tools/shots/tents_shot.tscn` | кадры лагеря в игре (с земли, сбоку, вблизи, сверху) и всех моделей × цветов |
| `tools/shots/campfire_shot.tscn` | кадры костра с дымом: со старта, вблизи, с воздуха в 300 и 500 м (`--wind=`, `--hour=`) |
| `configs/world_objects.json` | все параметры, посадки по локациям, пресеты качества |

## Подключение (главная сцена)
```gdscript
var world_objects: WorldObjects = preload("res://scenes/world_objects/world_objects.tscn").instantiate()
add_child(world_objects)                      # сначала в дерево (нужна камера для «активных»)
await terrain.loaded                           # или сразу, если рельеф уже загружен
world_objects.setup(terrain, atmosphere)       # atmosphere может быть null — тогда штиль
# столкновения (в _physics_process интегратора, отрезок пути за шаг):
var hit := world_objects.obstacle_hit(prev_pos, glider.global_position)  # {kind, point} или {}
# kind: building | tree | tent
var landings := world_objects.get_landing_sites()  # [{id, name, position, axis_deg, length_m, width_m}]
```
- Рельеф передаёт: `location_id`, `get_start_sites()`, `get_landing_sites()` (если есть), `height_at`,
  `latlon_to_local`, `center_lat/lon`. Атмосфера — `air_velocity_at`.
- Смена локации: снова `setup(...)` (старые объекты удаляются). Сигнал `built` — всё построено.
- Для места точки (`location_id` — ключ кеша `pt_…`) дома берутся из пятен застройки `built_patches.json` папки места (нет покрова — домов нет, ставятся только ветроуказатели на стартах).
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
✔ (исправлено) на средней скорости конус прямой и наклонён целиком, как на фото: изгиб дугой
∝ (1 − наполнение)^`bend_power` (2,5) — ткань натянута давлением, дугой висит только почти пустой конус;
болтание — хлопает хвост (`wave_count` 0,7), без S-изгиба посередине.
✘ у реального конуса обруч на вертлюге, в модели — рычаг без растяжек (видно только вблизи).

## Посадочные площадки (VR-12)
Данные — `configs/world_objects.json → landing.sites.<id локации>` (папка `configs/locations/` не наша):
`id, name, lat, lon, length_m, width_m, axis_deg, grass_color, windsock_at, trees[]`.
Если у рельефа есть `landing_sites` (terrain2 добавил их в `configs/locations/*.json`), запись с тем же
`id` берёт оттуда lat/lon; площадки рельефа без записи строятся с `landing.defaults` (ось — вдоль
горизонтали склона). Скошенное поле — меш по рельефу с полосами покоса (`draped.gdshader`),
вокруг — лесополосы (модели `assets/models/trees/`, масштаб по высоте), всё — препятствия. Заборов и ЛЭП нет.

| Локация | Площадка | Как выбрана |
|---|---|---|
| aushkul | aushkul_field (точка terrain2), 280×150 м, ось 90° | быстрое допущение: ось восток–запад под старты на В и З, берёзовый колок с севера |
| altai | поле у Озёрного, 51.83476, 85.81696, 300×200 м, ось 98° | точных координат официальной посадки у Синюхи нет в открытых источниках; взято реальное поле (выбрано по данным OSM на этапе подбора: `landuse=farmland`, 6 га, уклон ≤ 2°) в 3 км к ЗСЗ от западного старта |
| ongudai | ongudai_fields (точка terrain2), 300×150 м, ось 20° | ровный луг (1,5°) в долине севернее Онгудая, по долине против южного ветра |
| askarovo | idyash_west 300×160 м, ось 110°; biyagoda_east_field 250×140 м, ось 94° | точки terrain2 (уклон 0,6° и 2,5°), ось по ветру соответствующего старта, берёзовые колки |

## Тропы к стартам (`start_tracks.gd`, `StartTracks`)
Пешая грунтовая тропа вниз по склону от каждой площадки старта (`Terrain.get_start_sites()`). Дорог в игре нет, поэтому
тропа не привязана ни к дороге, ни к посёлку: всегда процедурная. Параметры — `configs/world_objects.json → start_tracks`.
- **Путь**: от старта вниз по склону (направление наибольшего спуска) на фиксированную длину `no_destination_length_m`
  (300 м); простая трассировка серпантином (`StartTracks._descend`) — прямой шаг, если уклон ≤ `max_slope_deg`, иначе
  отклонение к локальному контуру (перпендикуляр к градиенту рельефа — направление нулевого уклона, доля поворота —
  `contour_fractions`, по возрастанию, до подходящего по уклону). Прежние варианты цели (OSM-трек рядом со стартом,
  ближайшая дорога или посёлок, обход рек и озёр OSM) убраны вместе с данными OSM; остался спуск без цели — он и раньше
  был запасным для места без слоя OSM.
- **Отрисовка**: лента по рельефу (`draped.gdshader`), узкая и естественная — ширина
  гуляет вдоль пути `width_min_m`..`width_max_m` (период `width_wave_m`), цвет вытоптанной травы
  (`color`, приглушённый) с пятнами сильнее вытоптанной земли (`wear_color`/`wear_strength`, период
  `wear_wave_m`) вместо параллельных колей-рельсов; альфа вершин рвёт ленту на пятна/разрывы вдоль
  пути тем же периодом, край поперёк — мягкий и неровный (шум по миру `edge_noise_m` в шейдере), без
  резкого контраста с фоном. Подъём над рельефом минимальный (`lift_m`), depth-pull в шейдере против
  z-fighting. Видимость — `visibility_near_m`..`visibility_far_m` (50–800 м),
  плавно угасает за `fade_far_m` до границы. Свои тайлы (`Tracks`),
  не входит в `ObstacleIndex`.
- **Просека**: `WorldClearings.build_for` тоже строит тропы (тем же `StartTracks.plan`, с высотами
  рельефа локации — `<data_dir>/meta.json`, без живой ноды `Terrain`) и штампует их в маску
  (`clearings.start_track_margin_m` — обочина сверх `width_m`) — деревья/кусты/камни рельефа на
  тропу не ставятся.
- Проверка: `godot --headless --path . res://tests/run_tests.tscn -- --filter=world_objects`
  (`tests/world_objects/test_start_tracks.gd`) — тропа на каждый старт, уклон ≤ лимита, не в воде,
  меши строятся; кадр —
  `godot --path . res://scenes/world_objects/world_objects_preview.tscn -- --view=track`.

## Палатки у старта (`tent_camp.gd`, `TentCamp`)
Лагерь пилотов, чтобы старт выглядел живым: палаток **1 (игрок) + число ботов** (настройка «Другие пилоты в
небе», `configs/bots.json → count`; `--bots=N` — поверх). Ставит `WorldObjects.place_camp(start, heading,
terrain, count)`; в игре зовёт `WorldLink`, когда `Game` закончил загрузку полёта (`status_changed("")`) —
старт уже выбран, в том числе точка с карты. Новый старт той же локации — старый лагерь и его препятствия
убираются (`ObstacleIndex.remove_kind("tent")`).

Где встаёт (`TentCamp.plan`, всё — `configs/world_objects.json → tents`):
- центр лагеря — в кольце `distance_m` (30–150 м) от старта, ближе к `prefer_distance_m`; ровно
  (уклон ≤ `max_slope_deg` = 8° в радиусе `camp_flat_m`), лучше — на виду с глаз пилота на старте
  (`hidden_penalty`) и на чистой поляне (`scatter_penalty` за камни и кусты вокруг);
- только позади линии старта (`ahead_m`), вне прямоугольника мест ожидания ботов и коридора разбега
  (`bots.json → launch`: `behind_max_m`, `lateral_max_m`, `corridor_half_width_m` + `launch_zone_margin_m`);
- не на тропе к старту (`track_margin_m`), у домов
  (`building_margin_m`), не в лесу, воде, застройке, на скалах и снегу (`Terrain.surface_at`, `forest_at`),
  не на камнях и кустах крупнее `scatter_min_size_m` (RockScatter/ShrubScatter), не на бровке обрыва
  (`cliff_slope_deg` за краем пятна);
- кучкой, неровно: каждая следующая — рядом со случайной уже стоящей, зазор между пятнами `gap_m` (3–12 м,
  чаще ближе), в пределах радиуса кучки (`camp_radius_m`, растёт как √числа);
- типы — по весам (`types.*.weight`, навесов не больше `max_share`), цвета — перемешанная палитра `colors`
  (оранжевая, зелёная, синяя, жёлтая, красная, хаки) по кругу; вход — чаще по ветру (ветер — в склон, из
  курса старта), иногда боком или как попало; палатка наклонена по рельефу, чуть утоплена.
- детерминированно: сид — `seed` + место и курс старта. Ровного места нет — палаток меньше или ни одной.

Модели — `tools/blender/build_tents.py`: `dome2` (две дуги крест-накрест, провис между дугами, тамбур с
пологом, ~1,5 тыс. треугольников), `tunnel3` (три обруча, провис, скаты к колышкам, ~1,8 тыс.), `tarp`
(навес на двух стойках, ~0,5 тыс.); растяжки и колышки; `_LOD1` — несколько десятков треугольников, дальше
`lod_m`. Цвет — материалы `Fabric`/`Door` (полог темнее на `door_darken`), без логотипов. Палатки —
препятствия `tent` (коробки `types.*.half_size_m` × `height_m`) для `obstacle_hit`.
Кадры: `tools/shots/tents_shot.tscn -- --autostart --location=… --site=… --out=…` и `-- --models --out=…`.

## Костёр (`campfire.gd`, `Campfire`; VR-15 частично, VR-0)
Один костёр на лагерь (`place_camp` → `Campfire.plan`): у центра лагеря, сдвинут на `downwind_offset_m` по
ветру старта, не ближе `clear_of_tents_m` к палаткам, на ровном свободном месте (те же запреты, что у
палаток). Горит всегда. Не препятствие.
- Визуал без текстур и моделей: кольцо из `stones` приплюснутых камней + 4 полена «шалашом» + угли — один
  ArrayMesh на все костры; пламя — 14 частиц `ParticleProcessMaterial`, светящийся billboard
  (`flame_puff.gdshader`); свет — OmniLight3D 5 м без теней, мерцает, гаснет дальше `light_fade_m`.
- Дым — 26 клубов в мировых координатах (`smoke_particles.gdshader`): скорость клуба тянется (за `follow_s`)
  к «ветер + всплытие». Ветер — **локальный из модели** (`air_velocity_at` у костра на `sample_low_m` и
  `sample_high_m`, клуб берёт по своей высоте; вертикаль термика/склона — до `updraft_max_ms`), обновляется
  раз в `update_s` — порывы колышут весь шлейф. Всплытие `rise_speed` гаснет за `rise_decay_s` и делится на
  `1 + wind_damp·ветер`: в штиль — тонкая струйка почти вертикально, 3 м/с — наклонён, 7 м/с — прижат и
  тянется по ветру. Клубы светлые голубовато-серые, полупрозрачные клочья (`smoke_puff.gdshader`, освещение
  солнцем), тают за `smoke_lifetime_s` — в 10–20 м подъёма; с воздуха за сотни метров — едва заметная
  дымка. Рамка видимости частиц растягивается по сносу.
- Цена: 26 + 14 частиц, 1 меш (2 поверхности), 1 свет без теней; ветер — 2 запроса к атмосфере раз в 0,3 с.
Кадры: `tools/shots/campfire_shot.tscn -- --autostart --bots=4 --location=ongudai --wind=3 --from=launch
--hour=12 --out=… --tag=w3` (профиль — временный: `XDG_DATA_HOME=$(mktemp -d)`).
Тест `test_campfire.gd`: место у лагеря и не в палатке; дым в штиль вверх, по ветру — по ветру, сильный
ветер прижимает; ветер доходит до шейдера.

## Просеки для деревьев рельефа (terrain2 подключает сам)
Где деревья рельефа ставить нельзя: дома посёлков (описанная окружность дома + `house_margin_m`), поля посадок
(+ `landing_margin_m`), тропы к стартам (+ `start_track_margin_m` сверх ширины). Дорог и ЛЭП нет, их коридоров нет.
Параметры — `configs/world_objects.json → clearings`.

```gdscript
# 1) без нод, по id локации (пятна застройки места — BuiltPatches.for_dir, configs/locations/<id>.json, посадки из world_objects.json):
var c := WorldClearings.build_for(location_id)     # null — нет конфига локации; нет пятен — только посадки и тропы
c.is_clear_at(x, z)          # true — расчищено, дерево не ставить
c.image                      # Image L8, 255 — расчищено; 40 км / 10 м = 4000²
c.origin, c.cell_m           # мир (x, z) угла пикселя (0, 0); пиксель (i, j) ↔ origin + (i + 0.5, j + 0.5)·cell_m
# 2) через компонент: WorldObjects.clearing_mask_for(id) -> Image; world_objects.is_clear_at(x, z)
```
Дома в маске — те же, что рисует `VillageLayer` (один план `VillagePlacer`, кеш по ключу места). Если у места нет
`built_patches.json` (покров не собран) — маска содержит только посадки и тропы. Подключение в `TerrainTrees` — как
раньше: `ImageTexture.create_from_image(mask.image)` → `clearing_mask`, `clearing_origin`, `clearing_cell_m` в шейдере деревьев.
Проверка: `godot --headless --path . res://scenes/world_objects/world_objects_preview.tscn -- --location=<id> --mask=out.png`.

## Посёлки: процедурные дома (VR-6, VR-9, NO-2, NO-10)
**Данные** — только карта покрова ESA WorldCover (класс «застройка», код 50), без OpenStreetMap: сборщик места
(`SurfaceStage`) пишет `detail_built10.webp` (доля застройки в клетке 10 м = подвыборки 3×3 класса built / 9) и
`built_patches.json` (пятна: 8-связные компоненты клеток с долей ≥ `world.json → surface.built.threshold`, площадью не
меньше `min_area_m2`). Формат — контракт N1 (`docs/contracts/no-osm.md`), чтение — `BuiltPatches` (N2).
Имён посёлков нет (в WorldCover их нет), контуры реальных зданий не воспроизводятся.

**Расстановка** (`VillagePlacer`, контракт N3): внутри каждого пятна — сетка дворов со стороной √`yard_m2` (520 м², шаг
≈ 23 м), случайный сдвиг двора `yard_jitter` (0,4 стороны). Двор занят с вероятностью = доля застройки клетки
(`share_at`) × `fill`; клетки с долей ниже `min_share` (0,25) — не двор. В дворе дом (6×8…8×10 м, стены 2,6–3,2 м,
двускатная крыша), с вероятностью `shed_prob` (0,7) сарай и `banya_prob` (0,3) баня. Не ставится на склоне круче
`max_slope_deg` (14°); от уклона `slope_align_deg` (4°) дом поворачивается длинной стороной вдоль горизонтали, у края
пятна (градиент доли ≥ `edge_grad_min`) — параллельно краю, плюс разброс `angle_jitter_deg`. Генератор — от ключа места
и `id` пятна, без глобального RNG: у всех в сети при одном месте дома одни и те же. Нет пятен — домов нет. Запись дома —
`[x, z, w, l, угол_град, высота_стен_м, крыша]`.

Плотность подбиралась по числу зданий OSM, которые заменяют: NO-2 — двор 1400 м² (Алтай 25 167 домов против ≈ 27 тыс. зданий
OSM); NO-10 — 520 м² (плотный сельский посёлок): askarovo 13 953 → 36 582 дома, altai 65 838, aushkul 10 702,
ongudai 8 462; сборка WorldObjects askarovo 1,66 с. Число и положение домов не совпадают с реальными — это допущение
модели: посёлок читается с воздуха, но по нему нельзя искать конкретный дом.

**Отрисовка:** `VillageLayer` — коробки стен + призма крыши (`BuildingPlacer`), MultiMesh по тайлам 1 км
(`configs/world_objects.json → buildings`), видны 7 км; дома — препятствия `building` в `obstacle_hit` и штамп в маске просек.
**Мягкая подложка:** в раскраске рельефа цвет застройки берётся не из класса «застройка» 25 м, а из `detail_built10`,
сжатой до клеток `built_soft_cell_m` (50 м) билинейно: переход шириной ~30–60 м вместо квартальных блоков. У дальнего
слоя (far) built10 нет, там класс 25 м как был. Цена в кадре — в шуме (askarovo, chase@5: 5,25 → 5,37 мс).

**Чего нет:** дорог, ЛЭП (опоры, провода), заборов, зданий и полей OSM, имён посёлков, воды OSM. Вода — WorldCover и реки
по рельефу (см. `docs/guide/location-data.md`); реки и озёра объектами не рисуются — они в раскраске рельефа.

## Пасхалки (`easter_eggs.gd`, `EasterEggs`; контракт — `docs/contracts/easter-eggs.md`)

Редкие чисто визуальные детали мира и неба (лайнер, шары, …). Планировщик — узел `Game/EasterEggs`:
ход кадром (`_process`), только в полёте, время — `Game.world_time()`; расписание зависит от ключа
мира, `id` и окна времени (одно и то же при любом шаге кадра и после прыжка времени). Физике и сети не мешает.

Как добавить пасхалку:
1. Скрипт `scripts/world_objects/easter_eggs/<id>.gd`: `extends EasterEgg`; `static can_appear(ctx, cfg)`,
   `begin(ctx, cfg, rng, t0)` (все случайные параметры — только из `rng`), `update(ctx) -> bool`
   (поставить себя в момент `ctx.t`, `false` — кончилась). Ассеты — `assets/easter_eggs/<id>/`.
2. Блок `eggs.<id>` в `configs/easter_eggs.json`: `enabled`, `script`, `mode` (`interval` | `per_flight` |
   `condition`) + поля режима, `lifetime_s` (0 — постоянная) и свои поля; у каждого — `<поле>_doc`.
3. Кадр: `tools/shots/easter_egg_shot.sh <id> build/screenshots/easter_eggs/<№>.jpg` (форс `--egg=<id>`,
   камера `--look-at=egg`, печатает `EGG_GPU_MS`; `--egg=none` — база для цены). Тест
   `tests/world_objects/test_easter_eggs.gd` подхватывает новую пасхалку из конфига сам.

Запрещено (тест проверяет часть): физические тела, `Area3D`, `RayCast3D`, запись в `ObstacleIndex`,
`world_link.objects`, столкновения; `randf`/`randi`/`shuffle`/`pick_random` и прочий глобальный
генератор (только `rng`); запись в чужие узлы (воздух, крыло, рельеф, боты, небо, камера, `Engine`);
тексты, подсказки, HUD; тени у мешей дальше ~1 км. Проба каркаса — `easter_eggs/probe.gd`
(в игре выключена, `--egg=probe`).

**Место (`egg_place.gd`, `EggPlace`, `ctx.place`; К8)**: дешёвые проверки «логично ли здесь» —
высота/крутизна/класс поверхности, дно долины и `is_mountain`, ближайшее пятно застройки (без имени), вода по покрову
и маске рек, старты, лагерь, `find_point(rng, …, accept)` для выбора точки. Строится планировщиком один раз на
полёт (≈1 мс), только читает; нет WorldCover/пятен — «нет» (места яиц тогда — опорные точки по рельефу) (`{}`/`[]`/INF/NONE). Пороги — `configs/easter_eggs.json → place`.
Рядом в `EggContext` — дата, высота солнца, облачность, ветер и температура прогноза.

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
      [--view=start|landing|village|wires|sock|track] [--wind=км/ч] [--from=°] [--weather=…] [--time=с]
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
разбега и на местах ботов, не на тропе, не в воде/лесу, уклон ≤ 8°, зазоры, палатка — препятствие.

## Заменяемые ассеты
Пути — в конфиге: `windsock.scene_path`, `streamers.scene_path` (обёртки с `Pivot` + `Sock`/`Ribbon`, ткань
вдоль −Z; длина — `sock_length_m`/`ribbon_length_m`, отступ обруча — `root_offset_m`),
`landing.tree_scene_path`/`pine_scene_path`. Нет файла — процедурная заглушка и предупреждение.
Скриншоты моделей — `docs/models/screenshots/world/<модель>/{bottom,front,side,iso45}.png`
(`blender --background --python tools/blender/render_views.py -- world/<модель> docs/models/screenshots/world/<модель> bottom,front,side,iso45`).
