---
type: "contract"
status: "active"
module: "sea-ships"
area: "world"
updated: "2026-10-17"
summary: "Признак «море» (S1), маска моря far_sea.webp и SeaMask (S2), расстановка судов ShipPlacer (S3), модели судов ship_<вид>.glb (S4)."
related: ["docs/plan/sea-ships.md"]
contracts: [{"id": "S1", "version": 2}, {"id": "S2", "version": 2}, {"id": "S3", "version": 2}, {"id": "S4", "version": 1}]
---
# Контракты модуля sea-ships

Владелец всех — координатор sea-ships. Контрактные тесты — `tests/contracts/test_sea_ships_contracts.gd` (фильтр `sea_ships_contracts`), меняются только вместе с контрактом (версия +1, через координатора).

## S1. Итог проверки признака «море» — версия 2

- Владелец: SEA-1. Потребитель: координатор (шлюз), задачи этапа A (маска моря).
- Файл: `tools/research/sea_mask/summary.json` (UTF-8, пишется скриптом из того же каталога; запуск — команда в `README.md`).
- Поля верхнего уровня:
  - `criterion` (string) — признак словами: входные данные, пороги, порядок шагов;
  - `works` (bool) — признак надёжен по порогам ниже;
  - `fp_inland_cells` (int) — сумма клеток far-сетки (100 м), помеченных морем на всех внутренних местах (`kind` ≠ `sea`, кроме `edge`);
  - `tp_sea_min` (float 0..1) — минимум по морским местам доли воды дальше 2 км от берега, помеченной морем;
  - `where` (string) — где считать в игре: `build` (новая стадия сборки, файл в папке места) или `load` (при загрузке из имеющихся слоёв), с причиной;
  - `cost_ms` (float) — время счёта признака на одно место (far 160 км), мс, замер;
  - `places` (array) — по месту: `id`, `lat`, `lon`, `kind` (`sea` | `lake` | `reservoir` | `river` | `edge`), `water_cells` (int, вода far-сетки), `sea_cells` (int, помечено морем), `sea_far_cells` (int, вода дальше 2 км от берега), `sea_far_marked` (int, из них помечено), `level_m` (float, уровень поверхности главной водной компоненты места по слою, м), `touches_edge` (bool, компонента касается края far), `notes` (string).
- `level_margin_m` (float, верхний уровень) — наименьший `level_m` среди внутренних водоёмов, которые признак отвергает только по уровню (запас порога; v2).
- Пороги шлюза: `fp_inland_cells == 0`, `tp_sea_min >= 0.8`. `edge` (Каспий, Эйсселмер) — в таблицу, в пороги не входят; решение по ним — шлюз. Мёртвое море — `lake` (v2: озеро, входит в пороги).
- Нет данных места (сеть, отказ слоя) — место в `places` с `notes` о причине, `works` = false, пока не закрыто обязательное место.

## S2. Маска моря и уровень воды моря — версия 2

- Владелец: SEA-2. Потребители: `ShipPlacer` (S3), слой судов.
- Алгоритм — признак SEA-1 (`tools/research/sea_mask/README.md` §«Признак словами», эталон `sea_mask.py`/`sealib.py`) на сетке far:
  вода = класс 6 или класс 0 при h ≤ 0,5 м; компоненты 8-связные; компонента ≥ `min_cells` — море, если медиана h ≤ `median_max_m`,
  касается края far, 99-й процентиль h ≥ `q99_min_m`. Параметры — `configs/sea_ships.json → mask` (`min_cells` 100, `median_max_m` 0,25,
  `q99_min_m` −1,0) с ключами `_doc`.
- Чистая функция: `SeaMask.compute(heights: PackedFloat32Array, classes: PackedByteArray, w: int, h: int, cell_m: float, params: Dictionary) -> PackedByteArray`
  (`scripts/terrain/sea_mask.gd`, `class_name SeaMask`, static, без сцены). Результат — w·h байт, строки с севера на юг как у слоя:
  0 — не море; 1..255 — море, значение = min(255, 1 + floor(d / 100 м)), d — расстояние (евклидово, по центрам клеток) до ближайшей клетки не-моря
  внутри квадрата (край квадрата берегом не считается). Значение v ⇒ до берега не меньше (v − 1)·100 м.
- Стадия сборки `sea` (`SeaStage`, `scripts/terrain/build/sea_stage.gd`) — после `smooth`, до `osm_tiles`, в `LocationBuilder.default_stages()`;
  читает `far.webp`, `meta.json`, `far_surface.webp` из `ctx.dir`; пишет `far_sea.webp` (WebP lossless, L8, сетка far) и `sea.json`
  `{"version": 2, "sea_cells": int, "components": int, "levels_m": [float, …] (уровень воды каждой компоненты моря), "flattened_cells": int, "seconds": float}`.
- Уровень воды (v2, ответ пользователя на Q2): у каждой компоненты моря уровень L — мода высот far её клеток по бинам 0,1 м (океан и открытые моря — 0 м, Каспий ≈ −28 м).
  Стадия `sea` перезаписывает `far.webp`: в клетках моря h := L (батиметрия Terrarium убирается); вне моря (суша, озёра, водохранилища, Мёртвое море) — побайтно как было;
  `meta.json` — обновить min/max высот слоя, если они изменились. Так полёт (`height_at`), модель воздуха и рендер видят поверхность моря.
  Места из `res://` (учебный остров и др.) стадия не трогает: `load_for` только считает маску, высоты не меняет. Нет `far_surface.webp` → `ERR_UNAVAILABLE` (места без покрова — без судов).
  `Locations.FORMAT_VERSION` не меняется: стадия, которой нет в `build.json`, дособирается.
- Загрузка: `SeaMask.load_for(dir: String) -> Dictionary` → `{"image": Image (L8), "origin": Vector2 (x,z угла пикселя (0,0) в м места), "cell_m": 100.0}`
  или `{}`, если файла нет; нет файла, но есть far и far_surface (места из `res://`, учебный остров) — считается `compute` в рабочем потоке.
- Инварианты: без моря — все 0 и судов нет; одинаковый вход — побайтно одинаковый выход.
- Конфиг `configs/sea_ships.json` создаёт SEA-2 целиком: `mask` (S2), `placement` (S3: `cell_deg` 0.1, `p_cell` 0.15, `min_shore_m` 2000, `types` {tanker 1, bulk 1, container 1}), `types` (S4: tanker 250/44/15, bulk 225/32/12, container 300/48/13 — `length_m`/`beam_m`/`draft_m`), `render` (пусто, `{}` — заполняет SEA-4); у каждого ключа `_doc`.

## S3. Расстановка судов — версия 2

- Владелец: SEA-4. Потребители: слой судов (рендер), тесты.
- `ShipPlacer` (`scripts/world_objects/ship_placer.gd`, static): `ships_for(mask: Dictionary, center_lat: float, center_lon: float, params: Dictionary, height_fn: Callable) -> Array[Dictionary]`,
  элемент `{"type": String (вид из S4), "x": float, "y": float (уровень воды L, м), "z": float (м места, оси как у Terrain), "heading_rad": float (0 — нос на −Z/север, по часовой), "cell": Vector2i}`.
- Детерминизм по миру: мировая клетка `cell = Vector2i(floor(lon / cell_deg), floor(lat / cell_deg))`, `cell_deg` — `configs/sea_ships.json → placement.cell_deg` (0,1° ≈ 11 км).
  Из хеша клетки (`TreeCell.hash` или `RockScatter.hash01`, без `RandomNumberGenerator` с глобальным сидом): есть ли судно (вероятность `placement.p_cell`),
  точка внутри клетки (lat/lon), вид (`placement.types` с весами), курс. Перевод lat/lon ↔ x,z — `Geo` (`scripts/terrain/geo.gd`), как у мест.
  Судно ставится, если точка внутри far и значение маски S2 ≥ 1 + `placement.min_shore_m`/100 (по умолчанию 2000 м). Одна и та же точка мира в двух местах
  с разными центрами даёт то же судно (тест).
- Высота: ватерлиния y = высота рельефа в точке (`Terrain.height_at`; после выравнивания S2 v2 это уровень воды L, у океана 0 м). `ships_for` получает высоту через параметр `height_fn: Callable` (x, z → м) последним аргументом.
- Нет маски или пустая — пустой массив; слой судов не создаёт узлов (ноль цены).

## S4. Модели судов — версия 1

- Владельцы: SEA-3 (танкер), далее сухогруз и контейнеровоз. Потребитель: слой судов.
- Файл на вид: `assets/models/ships/ship_<вид>.glb`, вид ∈ `tanker`, `bulk`, `container`; исходник `assets/source/ships/ship_<вид>.blend`;
  сборка `blender --background --python tools/blender/build_ship_<вид>.py` (Blender 4.3), общие функции — `tools/blender/bl_util.py` (не ломать чужое).
- Узлы `MeshInstance3D`: `<вид>_LOD0` (≤ 4000 треугольников), `<вид>_LOD1` (≤ 600), `<вид>_LOD2` (≤ 80, силуэт корпуса и надстройки); поиск `find_child` по дереву.
- Оси: +Y вверх, нос к −Z, начало координат — на ватерлинии в середине длины; масштаб 1 = 1 м, размеры реальных судов (длина 180–330 м), числа — в `configs/sea_ships.json → types.<вид>` (`length_m`, `beam_m`, `draft_m`).
- Материал: вершинные цвета или одна текстура ≤ 512×512 (сжатие VRAM, мипмапы) на вид; без прозрачности; тени отбрасывает только LOD0.
