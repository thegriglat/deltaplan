---
type: "contract"
status: "active"
module: "volcano-island"
area: "world"
updated: "2026-10-17"
summary: "Вулканический остров: место только для «Тренировки» (VI-К1), группы окна «Тренировка» (VI-К2), запекание мест (VI-К3)."
related: ["docs/plan/volcano-island.md", "docs/contracts/training-island.md", "docs/guide/location-data.md"]
contracts: [{"id": "VI-К1", "version": 1}, {"id": "VI-К2", "version": 1}, {"id": "VI-К3", "version": 1}]
---
# Контракты модуля volcano-island

Владелец всех — координатор volcano-island; меняет только он (версия +1, потребителям — заметка в карточку).
Контрактные тесты: `tests/contracts/test_volcano_island_k1.gd`, `…_k2.gd` (фильтр `volcano_island`); VI-К3 (скрипт) — проверки карточки VI-4
(`--check` кодами). Пишет задача-владелец первым шагом, меняются только вместе с контрактом.
Без изменений берутся контракты учебного острова (`docs/contracts/training-island.md`): TI-К1 (папка встроенного места формата 4,
`"bundled": true`), TI-К2 v2 (фиксированная погода старта `start_sites[].weather`), TI-К3 v3 (запечённое поле ветра, `model_hash`).

**Имена.** Реальное место не раскрывается: в конфиге (`name`, `_doc`), `locale/ui.csv`, `docs/guide`, `CHANGELOG.md`, `ASSETS.md`, описаниях
места и на сайте — без названий острова и его мест (Пасха, Рапа-Нуи, Поике, Рано-Кау, Ханга-Роа, Теревака, Анакена и т. п.). Атрибуции
источников данных (Copernicus, ESA WorldCover, OpenStreetMap) — обычные, без названия острова. В журнале модуля и в коде инструментов
`tools/terrain/volcano/` координаты и рабочие пометки допустимы.

## VI-К1. Вулканический остров — встроенное место только для «Тренировки» — версия 1

- Владелец данных: VI-1 (`tools/terrain/volcano/`); владелец кода (`training_only`, тайлы OSM из папки места): VI-2.
  Потребители: `Locations` (`scripts/terrain/build/locations.gd`), `Terrain`, загрузка OSM (`OsmData.load_for`, `scripts/world_objects/osm_data.gd`),
  каталог «Популярные места» (`tools/places/add_builtin_places.py` → `data/places/hg_takeoffs.json`), меню полёта, `WorldKey`,
  VI-3 (карточки), VI-5 (погода, воздух, запекание), тесты мест.
- id `volcano_island`; конфиг `configs/locations/volcano_island.json`; данные `res://data/locations/volcano_island/`.
  `name` = `loc_volcano_island` (ru «Вулканический остров», en «Volcanic Island»); имена стартов — `site_volcano_island_<id>` (нейтральные, без топонимов).
- Ключи конфига: как у `training_island` (`bundled`, `center_lat`, `center_lon`, `utc_offset_h`, `start_sites`, `landing_sites`, `render`,
  `start_position_agl_m`, `start_clearing_radius_m`, `country`) и:
  - `"bundled": true` (TI-К1): данные из `res://`, без сборщика и сети; `"synthetic"` — не ставить (место реальное);
  - `"training_only": true` (новый): место доступно только из окна «Тренировка» (VI-К2): `Locations.builtin_at` его не возвращает
    (точка с карты в него не превращается), его старты не попадают в `data/places/hg_takeoffs.json` (add_builtin_places.py пропускает),
    его нет ни в одном списке мест меню полёта; восстановленный `user://last_flight.json` / повтор с таким местом в меню полёта — место по
    умолчанию (как при неизвестном месте); запуск из «Тренировки», по ключу мира (`WorldKey`, сеть) и из командной строки работает.
    API: `Locations.is_training_only(id) -> bool` (= `is_builtin(id) and config(id).training_only`);
  - `"country": ""`; `dem`, `surface`, `rivers` — по желанию (параметры пересборки для `tools/terrain/volcano/`), игрой для bundled-места не читаются.
- Центр места — на суше: (0, 0) выше 0,5 м и не вода (`Terrain.is_sea` = false); `utc_offset_h` = −6 (поясное время без летнего).
- Папка данных — формат 4 (`Locations.FORMAT_VERSION`), собрана обычным сборщиком (`LocationBuilder`: Copernicus GLO-30, Terrarium, ESA WorldCover,
  реки, сглаживание, тайлы OSM) и скопирована как есть: `meta.json`, `detail.webp` (1601², 25 м), `far.webp` (1601², 100 м), `*_surface.webp`,
  `*_water.webp`, `detail_detail10.webp`, `detail_built10.webp`, `built_patches.json`, `surface.json`, `osm_tiles.json`, `build.json`
  (`complete: true`, `format_version` 4); без `*.import`, `*.remap`, `location.json`. Рельеф не правится (реальный, как есть).
  - Тайлы OSM — в папке места: `osm/<j>/<i>.dpt` (байты как в `user://osm_tiles/v1/<j>/<i>.dpt`, формат модуля osm-tiles) для каждого
    тайла со статусом `"ok"` в `osm_tiles.json`; `"none"` — файла нет. Статуса `"missing"` в bundled-месте нет.
  - Загрузка OSM bundled-места (VI-2): корень тайлов — `Locations.osm_root(id)` = `data_dir(id).path_join("osm")` для bundled-места,
    `OsmTilesStage.cache_root()` для остальных; `OsmData.load_for(…, cache_dir)` получает его от вызывающего. Сеть и `user://osm_tiles` для
    bundled-места не используются. У `training_island` тайлов нет (`osm_tiles.json` пуст) — поведение то же.
  - Экспорт: файлы папки, включая `osm/**/*.dpt`, попадают в пак сырыми (`export_presets.cfg`, как у `training_island`).
  - Размер папки без `air/` ≤ 12 МБ.
- Пересборка: `tools/terrain/volcano/build.sh` (сеть, свой временный профиль Godot) → та же папка; повтор при тех же источниках даёт те же
  высоты и классы (побитного равенства WebP не требуется). Параметры — в `tools/terrain/volcano/README.md`.
- Старты `start_sites` (id фиксированы; координаты — ориентир исследования, VI-1 уточняет под правила):
  | id | вид | ориентир | курс |
  |---|---|---|---|
  | `east_cliffs` | склон восточного плато над обрывами | −27,1049; −109,2384 (199 м) | ≈ 100° |
  | `crater_ridge` | склон/гребень кратера на юго-западе | −27,1805; −109,4131 или гребень −27,170; −109,4136 | 75–110° |
  | `plateau_landing` | посадка: короткий подлёт, мишень на плато | −27,1103; −109,2414 | ≈ 90° |
  | `thermal_slope` | термики — **только если** VI-1/VI-5 найдут старт с термиками над сушей | — | — |
  Каждый старт проходит правила `tests/terrain/test_locations.gd` (уклон 8–35°, земля в 60 м впереди ниже > 5 м, не лес). Подветренных стартов
  (при пассате с 110°) нет. `weather` (TI-К2 v2) — пишет VI-5; до VI-5 у стартов `weather` нет.
- Посадки `landing_sites` (уклон < 10°, не лес, не вода): `landing_target` — мишень на плато для `plateau_landing` (0,15–1,5 км от старта),
  у каждого склонового старта — посадка в пределах планирования (k ≈ 6 от высоты старта над ней); детали — `configs/world_objects.json → landing.sites.volcano_island`.
- Нет папки или файла слоя — загрузка падает с сообщением (TI-К1), не сборкой из сети.

## VI-К2. Окно «Тренировка»: группы мест — версия 1

- Владелец: VI-3. Потребители: `TrainingMenu` (`scripts/ui/training_menu.gd`), главное меню (`scripts/ui/start_menu.gd`),
  тесты (`tests/ui/test_training_menu.gd`, `tests/ui/test_training_island_menu.gd`), съёмка (`tools/shots/training_island_menu_shot.gd`), VI-5.
- `configs/training.json`:
  ```json
  {"_doc": "…", "groups": [
    {"id": "training_island", "title_key": "loc_training_island", "location": "training_island", "cards": [ …4 карточки как сейчас… ]},
    {"id": "volcano_island", "title_key": "loc_volcano_island", "location": "volcano_island", "cards": [ … ]}
  ]}
  ```
  Карточка — как сейчас: `id`, `title_key`, `what_key`, `site`, `goal` (GL-К1: `kind`, `level` = custom, `value`). Ключа `location` верхнего уровня нет.
- Карточки острова `volcano_island` (v1): `cliffs` → `east_cliffs`, цель duration 600 с; `crater` → `crater_ridge`, цель duration 600 с;
  `landing` → `plateau_landing`, цель landing 25 м. Тексты — `training_volcano_<id>`, `training_volcano_<id>_what` (нейтральные).
  Карточку термиков добавляет VI-5, если старт `thermal_slope` есть (версия +1).
- `TrainingMenu.load_cards() -> Dictionary` = `{"groups": [...]}`; каждой карточке при чтении добавлено `"location"` её группы.
  Окно: вкладки (`TabContainer`) по группам в порядке файла, заголовок вкладки — `tr(title_key)`, открыта первая; внутри — сетка 2 столбца, как сейчас.
  Группа, чьё место не существует (`Locations.exists` = false) или без карточек, — не показывается.
  `chosen(card)` — карточка с `location`. `settings_for(card, base) -> FlightSettings` — место из `card.location` (параметра `loc` нет).
  `press_card(i: int, group: int = 0)`. Первые 4 карточки учебного острова и их поведение не меняются.

## VI-К3. Запекание полей всех встроенных мест — версия 1

- Владелец: VI-4. Потребители: new-release (`.claude/skills/new-release/SKILL.md`), VI-5, `docs/guide/location-data.md`.
- `tools/terrain/bake_all.sh [--check] [--id <место>]` — для каждого места с `"bundled": true` в `configs/locations/*.json` (или одного `--id`) и каждого его
  старта с `weather`: запечь (`tools/terrain/bake_air.tscn`, GPU, окно) или проверить (`--check`, без GPU). Список мест и стартов — из конфигов, не в скрипте.
  `--check`: код 0 — все поля свежие; код 1 — хоть один устарел или нет файла (строка на каждый); код 2 — ошибка запуска.
  Профиль Godot — `XDG_DATA_HOME` из окружения; после прогона `git checkout -- project.godot`.
- `tools/terrain/island/bake_all.sh` удаляется; ссылки (new-release, `docs/guide/location-data.md`, `docs/guide/air-model/runtime.md`, README генератора) —
  на новый путь. Формат файлов поля — TI-К3 v3 без изменений.
