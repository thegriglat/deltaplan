---
type: "contract"
status: "active"
module: "sea-ships"
area: "world"
updated: "2026-10-17"
summary: "Признак «море» (S1), маска моря far_sea.webp и SeaMask (S2), расстановка судов ShipPlacer (S3), модели судов ship_<вид>.glb (S4)."
related: ["docs/plan/sea-ships.md"]
contracts: [{"id": "S1", "version": 2}, {"id": "S2", "version": 3}, {"id": "S3", "version": 3}, {"id": "S4", "version": 1}]
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

## S2. Маска моря и уровень воды моря — версия 3

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
  Класс покрова (v3): стадия перезаписывает `far_surface.webp` — в клетках моря класс 0 (нет данных WorldCover, открытый океан) := 6 (вода); остальные классы и клетки вне моря — побайтно как было (иначе море за детальным квадратом рисуется и греется как суша). `sea.json` — поле `reclassed_cells`.
  Места из `res://` (учебный остров и др.) стадия не трогает: `load_for` только считает маску, высоты не меняет. Нет `far_surface.webp` → `ERR_UNAVAILABLE` (места без покрова — без судов).
  `Locations.FORMAT_VERSION` не меняется: стадия, которой нет в `build.json`, дособирается.
- Загрузка: `SeaMask.load_for(dir: String) -> Dictionary` → `{"image": Image (L8), "origin": Vector2 (x,z узла (0,0) сетки far в м места; клетка — ±50 м вокруг узла), "cell_m": 100.0}`
  или `{}`, если файла нет; нет файла, но есть far и far_surface (места из `res://`, учебный остров) — считается `compute` в рабочем потоке.
- Инварианты: без моря — все 0 и судов нет; одинаковый вход — побайтно одинаковый выход.
- Конфиг `configs/sea_ships.json` создаёт SEA-2 целиком: `mask` (S2), `placement` (S3 v3: `cell_deg` 0.02, `shore_min_m` 3000, `shore_max_m` 15000, `center_max_m` 30000, `n_min` 2, `n_max` 6, `min_sep_m` 1500, `types` {tanker 1, bulk 1, container 1}), `types` (S4: tanker 250/44/15, bulk 225/32/12, container 300/48/13 — `length_m`/`beam_m`/`draft_m`), `render` (пусто, `{}` — заполняет SEA-4); у каждого ключа `_doc`.

## S3. Расстановка судов — версия 3

- Владелец: SEA-10 (было SEA-4). Потребители: слой судов (рендер), тесты.
- `ShipPlacer` (`scripts/world_objects/ship_placer.gd`, static): `ships_for(mask: Dictionary, center_lat: float, center_lon: float, params: Dictionary, height_fn: Callable) -> Array[Dictionary]`,
  элемент `{"type": String (вид из S4), "x": float, "y": float (уровень воды, м), "z": float (м места, оси как у Terrain), "heading_rad": float (0 — нос на −Z/север, по часовой), "cell": Vector2i}`.
- Плотность (v3, ответ пользователя на Q3, 2026-10-17): на место 2–6 судов в полосе 3–15 км от берега, видимые с берега места; не десятки у глухих островов.
  1. Кандидаты — по мировым клеткам `cell_deg` (`placement.cell_deg`, 0,02° ≈ 2 км): из хеша клетки (`TreeCell.hash`/`RockScatter.hash01`, без глобального сида) — точка в клетке, вид (`placement.types` с весами), курс, ранг `r` ∈ [0,1).
     Кандидат годен, если точка внутри far, значение маски S2 в ней даёт расстояние до берега в `[placement.shore_min_m, placement.shore_max_m]` (3000…15000) и до центра места ≤ `placement.center_max_m` (30000).
  2. Число судов места `N = n_min + hash(ключ места) mod (n_max − n_min + 1)` (`placement.n_min` 2, `n_max` 6); ключ места — мировая клетка центра (`LocationCache.key_for`-сетка 0,05°), без сида и без пилота.
  3. Берутся N годных кандидатов с наименьшим `r` (не ближе `placement.min_sep_m` 1500 м друг к другу); годных меньше N — все.
  Кандидат одной мировой клетки в двух местах одинаков (точка, вид, курс); набор взятых зависит от места (тест: одно место — один и тот же набор при повторе).
- Высота: ватерлиния y = высота рельефа в точке (`height_fn(x, z)`, в игре `Terrain.height_at`; после S2 v2 это уровень воды, у океана 0 м).
- Нет маски, пустая или нет годных кандидатов — пустой массив; слой судов не создаёт узлов (ноль цены).

## S4. Модели судов — версия 1

- Владельцы: SEA-3 (танкер), далее сухогруз и контейнеровоз. Потребитель: слой судов.
- Файл на вид: `assets/models/ships/ship_<вид>.glb`, вид ∈ `tanker`, `bulk`, `container`; исходник `assets/source/ships/ship_<вид>.blend`;
  сборка `blender --background --python tools/blender/build_ship_<вид>.py` (Blender 4.3), общие функции — `tools/blender/bl_util.py` (не ломать чужое).
- Узлы `MeshInstance3D`: `<вид>_LOD0` (≤ 4000 треугольников), `<вид>_LOD1` (≤ 600), `<вид>_LOD2` (≤ 80, силуэт корпуса и надстройки); поиск `find_child` по дереву.
- Оси: +Y вверх, нос к −Z, начало координат — на ватерлинии в середине длины; масштаб 1 = 1 м, размеры реальных судов (длина 180–330 м), числа — в `configs/sea_ships.json → types.<вид>` (`length_m`, `beam_m`, `draft_m`).
- Материал: вершинные цвета или одна текстура ≤ 512×512 (сжатие VRAM, мипмапы) на вид; без прозрачности; тени отбрасывает только LOD0.
