---
type: "contract"
status: "active"
module: "regional-veg"
area: "world"
updated: "2026-10-18"
summary: "Регион места biomes.json и Biome (К1), набор пород места (К2), модели новых пород (К3), профиль домов (К4), полог (К5), модели домов (К6)."
related: ["docs/plan/regional-veg.md", "docs/research/regional-vegetation.md", "docs/contracts/scene-look.md"]
contracts: [{"id": "RV-К1", "version": 1}, {"id": "RV-К2", "version": 1}, {"id": "RV-К3", "version": 1}, {"id": "RV-К4", "version": 1}, {"id": "RV-К5", "version": 1}, {"id": "RV-К6", "version": 1}]
---
# Контракты regional-veg

Владелец всех — координатор regional-veg. Контрактный тест — `tests/contracts/test_regional_veg_contracts.gd`
(фильтр `regional_veg_contracts`; функции `test_k<n>_*`). Тест пропускает проверку, пока артефакта нет (файл/класс не создан),
и падает, если артефакт есть, а формат другой. Правка интерфейса — только координатор: версия +1, этот файл и тест — в том же шаге.

## RV-К1 v1 — регион места: `configs/biomes.json` и `Biome`

- Владелец: RV-1. Потребители: RV-9 (`terrain.gd`, конфиг домов), RV-6, RV-8 (ключи профилей).
- Файл `configs/biomes.json` (UTF-8, ≤ 8 КБ, генерирует `tools/world/bake_biomes.py`; секции `profiles` — вручную в скрипте/шаблоне, перезапекание их сохраняет):
  ```
  {
    "version": 1,
    "source": "Köppen–Geiger, Beck et al. 2018, CC BY 4.0, doi:10.1038/sdata.2018.214",
    "classes": ["arid","tropical_wet","savanna","mediterranean","subtropical","temperate","boreal","alpine_ice"],
    "tree": [[feat, thr, left, right] | [-1, class_index], ...],   // узел 0 — корень
    "exceptions": [{"name": "rapa_nui", "lat": [lat_min, lat_max], "lon": [lon_min, lon_max], "profile": "island"}, ...],
    "profiles": {"<id>": {"trees": {...}, "terrain_look": {...}, "scene_look": {...}, "buildings": {...}}, ...}
  }
  ```
  - Узел дерева: `feat` 0 — широта, 1 — долгота (градусы, + север/восток, долгота в [−180, 180)); переход влево, если `x <= thr`, иначе вправо; `left`/`right` — индексы узлов. Лист `[-1, k]` → `classes[k]`. Глубина ≤ 16, листьев 128…256.
  - Исключения проверяются по порядку, первое совпадение (границы включительно) побеждает и даёт `profile` напрямую. Прямоугольники не пересекают линию перемены дат.
  - `profiles` — ключи: все 8 `classes` + доп. профили, на которые ссылаются исключения (минимум `island`). Каждая секция необязательна; содержимое — частичные словари тех же ключей, что в `configs/world.json → trees|terrain_look|scene_look` и `configs/world_objects.json → buildings` (+ ключи RV-К2/К4/К5).
- API `scripts/world/biome.gd`, `class_name Biome`, статический, данные читаются один раз и кешируются:
  - `static func at(lat: float, lon: float) -> String` — id профиля (исключение → иначе лист дерева). Нет файла или битый — `"boreal"`.
  - `static func profile(id: String) -> Dictionary` — копия профиля; неизвестный id — `{}`.
  - `static func classify_tree(lat: float, lon: float) -> String` — только дерево (для теста и отчёта точности).
- Слияние (делает RV-9): `trees = world.trees ← profile.trees ← location.trees`, так же `terrain_look`, `scene_look`; `buildings = world_objects.buildings ← profile.buildings` (`Config._deep_merge`, место побеждает). Высота не входит в `at`: пояса пород по высоте — существующие `trees.species.*.min_m/max_m`.
- Эталонные точки (тест, `Biome.at`):

  | Место | lat, lon | профиль |
  |---|---|---|
  | Анси (Альпы) | 45.90, 6.15 | temperate |
  | Казбеги (Кавказ) | 42.66, 44.64 | temperate |
  | Онгудай (Алтай) | 50.79, 86.13 | boreal |
  | Аушкуль (Урал) | 54.72, 59.69 | boreal |
  | Флорианополис | −27.72, −48.78 | subtropical |
  | Манаус | −3.10, −60.00 | tropical_wet |
  | Рапа-Нуи | −27.12, −109.35 | island |
  | Ницца | 43.70, 7.26 | mediterranean |
  | Кейптаун | −33.95, 18.42 | mediterranean |
  | Покхара | 28.21, 83.99 | subtropical |
  | Кернс | −16.92, 145.77 | tropical_wet |
  | Тегеран | 35.70, 51.40 | arid |

- Исключение «Сибирь/Урал»: 49…75° с. ш., 55…180° в. д. → `boreal`. Профиль `boreal` не меняет ни одного ключа деревьев, полога и домов (`trees.set` = `["pine","cedar","larch","birch","spruce"]`, остальное пусто).

## RV-К2 v1 — набор пород места

- Владелец: RV-2. Потребители: RV-9, RV-4/5/7 (имена пород), `TerrainTreeModels`, `ForestImpostors`, `TreeCrosses`, `TreePlacer`, тесты деревьев.
- Реестр пород — `configs/world.json → trees` (все известные породы, не только места):
  - `models{sp: path}` — как сейчас;
  - `atlas_cell{sp: int}` — ячейка общего атласа импостеров 4×2 (`col = cell % 4`, `row = cell / 4`): pine 0, cedar 1, larch 2, birch 3, spruce 4, oak 5, palm 6, tropical 7;
  - `season_kind{sp: int}` — 0 вечнозелёная (не желтеет, не сбрасывает листву), 1 лиственная (сроки берёзы), 2 лиственница: pine 0, cedar 0, larch 2, birch 1, spruce 0, oak 1, palm 0, tropical 0;
  - `conifer{sp: bool}` — тон хвойных в импостерах: pine, cedar, spruce, larch — как сейчас (`SL_CONIFER` = 1,1,0,0,1 → larch false), oak/palm/tropical false.
- Набор места — `trees.set: Array[String]`, 1…6 имён из реестра, порядок = локальный индекс породы `sp` (вход `TreeCell.species`). Нет ключа — `["pine","cedar","larch","birch","spruce"]` (текущее поведение).
- `TreePlacer`: константа `SPECIES` заменяется полем экземпляра `species: PackedStringArray` (из `cfg.set`); `const DEFAULT_SET` — старые 5. Все потребители берут набор из конфига/экземпляра, не из константы. `variants` — общий (8); у породы с меньшим числом вариантов в glb вариант `v % n_available` (как сейчас в `_load_species`).
- Загрузка: `TerrainTreeModels`, `TreeCrosses`, `request_preload` грузят glb только пород набора; порода набора без файла → `setup()` false (как сейчас).
- Шейдеры `tree_cross.gdshader`, `forest_impostors.gdshader`: `const int MAX_SP = 6`; массивы `sp_*[MAX_SP]`; `uniform int sp_count`; `uniform float sp_kind[MAX_SP]` (season_kind) вместо `SL_KIND`/`SL_DECID`; `uniform float sp_conifer[MAX_SP]` вместо `SL_CONIFER`; `uniform float sp_cell[MAX_SP]` — ячейка атласа (импостеры; `cell_uv = vec2(mod(cell, cols), floor(cell / cols))` по `atlas_cells`). Циклы — `k < sp_count`. Модели: `sl_tree_kind` = `season_kind[sp]` из конфига, жёсткий список в `TerrainTreeModels.season_kind` убрать.
- Инвариант (тест «Алтай не изменился»): при наборе по умолчанию для `ongudai` и `altai` — те же экземпляры (порода-имя, вариант, позиция, масштаб, цвет) у `TreePlacer.build`, те же uniform-значения пород в крестах и импостерах, что до правки (эталон снять до правки и сохранить в тесте/фикстуре).

## RV-К3 v1 — модели новых пород

- Владельцы: RV-3 (генератор), RV-4 `oak`, RV-5 `palm`, RV-7 `tropical`. Потребители: RV-9, `TerrainTreeModels`, `TreeCrosses`, атлас.
- Имена пород: `oak` (дуб/бук, округлая широкая лиственная), `palm` (пальма: перья-карточки на тонком стволе), `tropical` (крупная купольная вечнозелёная лиственная).
- Сборка: `xvfb-run -a blender --background --python tools/blender/build_trees.py -- <sp>` (Blender 4.3) — собирает только `<sp>`, остальные файлы не трогает. `-- --atlas-only` — собирает `assets/models/trees/trees_impostor_atlas.png` (1024², 4×2 ячейки 256×512, ячейка — `atlas_cell` RV-К2) из `assets/source/trees/tree_<sp>_v0_impostor.png`, без пересборки пород.
- `tools/blender/tree_params.json`: запись на породу в существующей схеме + `"variants": 4` (необязательный ключ на породу; нет — `lod.variants`).
- Файл `assets/models/trees/tree_<sp>.glb`: ноды `V{v}_LOD0`, `V{v}_LOD1`, `V{v}_LOD2`, v = 0…3; LOD2 — два скрещённых квада импостера (как у старых пород); материалы `Bark_<sp>`, `Leaf_<sp>`, `Impostor_<sp>_v<v>`. Размер glb ≤ 1,5 МБ. Треугольники LOD0 — не больше, чем у самой тяжёлой из старых пород; LOD1 ≤ LOD0/3.
- Текстуры (процедурные, `tools/blender/tree_textures.py`): листва 512×512 RGBA, кора 256×512 RGB, импостер варианта 256×512 RGBA; импорт Godot — как у старых (сжатие VRAM + мипмапы).
- Высота LOD0 (м, по вариантам): oak 15…30, palm 8…25, tropical 20…40. Исходники — `assets/source/trees/` (`tree_<sp>.blend`, `<sp>_leaf.png`, `<sp>_bark.png`, `tree_<sp>_v<v>_impostor.png`).
- Превью для шлюза: `tools/blender/render_trees.py` → `/home/greg/deltaplan/build/screenshots/regional-veg/models/<sp>/` (4 варианта рядом + один кадр «сверху под 45°, 300 м»).

## RV-К4 v1 — профиль домов

- Владелец: RV-6. Потребители: RV-9 (профили в `biomes.json → profiles.*.buildings`).
- Ключи `configs/world_objects.json → buildings` (значения по умолчанию = текущее поведение):
  - `village_roof`: `"gable"` (по умолчанию) | `"hip"` | `"flat_parapet"`;
  - `city_roof`: `"flat"` (по умолчанию) | `"flat_parapet"`;
  - `hip_pitch_deg`: 20 (уклон вальмовой, 15…25);
  - `parapet_h_m`: 0,8, `parapet_t_m`: 0,25;
  - `max_levels`: 0 (= без потолка); иначе потолок этажей для домов, высота которых — по правилу (`by_rule`, не из тегов OSM): `wall_h ≤ max_levels · height_rule.level_m`; `metro`-множитель потолок не превышает;
  - палитры `style.<city|village|industrial>.{wall_colors, roof_colors}` и `roof_pitch_deg` — существующие ключи.
- H1 `flat_parapet`: плоская крыша + парапет — кольцо из 4 тонких коробок по периметру (высота `parapet_h_m`, толщина `parapet_t_m`), цвет стен. H2 `hip`: четырёхскатная крыша (своя `ArrayMesh`, без текстур), цвет крыши из палитры, уклон `hip_pitch_deg`. Обе — MultiMesh, как стены/крыши сейчас; без текстур.
- Инвариант: без новых ключей вид, число экземпляров и цвета домов — как до правки (тесты `building` проходят без изменений).

## RV-К5 v1 — вечнозелёный полог (дополняет SL-К2 v2)

- Владелец: RV-8. Потребители: RV-9 (профили `scene_look.evergreen`).
- Ключ `scene_look.evergreen` (0…1, по умолчанию 0): доля лиственного полога рельефа (часть 1 − con_p в `sl_canopy_season`), которая вечнозелёная. Осенняя окраска и листопад полога умножаются на `1 − evergreen`; хвойная часть и лиственница — как сейчас.
- Uniform `sl_evergreen` (float) во всех материалах с include scene_look (тем же путём, что `sl_season_*`). CPU-зеркало: `SeasonLook.state(...)` дополнительно отдаёт `canopy_autumn` и `canopy_bare` = `autumn·(1 − evergreen)`, `bare·(1 − evergreen)` (`evergreen` из `look`).
- Деревья-модели, кресты, импостеры: вечнозелёность — через `season_kind` 0 (RV-К2), не через `sl_evergreen`.
- Инварианты теста: `evergreen` = 0 → всё как до правки; 1 октября, 51°, 1000 м, `evergreen` = 1 → `canopy_autumn = canopy_bare = 0`; при `evergreen` = 1 значения `green`, `dry`, `snow_*` не меняются.

## RV-К6 v1 — модели домов

- Владельцы: RV-11 `rondavel`, RV-12 `tin_house`, RV-13 `stilt_house` (модели), RV-10 (расстановка). Потребители: RV-9 (профили `buildings.village_models`).
- Модели: `rondavel` — круглая хижина, глинобитная стена, коническая соломенная крыша со свесом (Африка, саванна, тропики); `tin_house` — одноэтажный прямоугольный дом, низкая двускатная или односкатная крыша из профлиста 8…15° (острова Тихого океана, Латинская Америка, Ханга-Роа); `stilt_house` — дом на сваях с верандой и крышей 20…30° (влажные тропики).
- Сборка: свой скрипт `tools/blender/build_house_<name>.py`, `[xvfb-run -a] blender --background --python tools/blender/build_house_<name>.py` (Blender 4.3; общие помощники — `tools/blender/bl_util.py`, не менять). Исходник — `assets/source/houses/house_<name>.blend`.
- Файл `assets/models/houses/house_<name>.glb`: ноды `LOD0`, `LOD1`, `LOD2` (`MeshInstance3D`, поиск `find_child`). Треугольники: LOD0 ≤ 800, LOD1 ≤ 200, LOD2 ≤ 40 (коробка + крыша). glb ≤ 300 КБ.
- Оси и размер: метры, +Y вверх, начало координат — центр контура дома на уровне земли (низ стен/свай y = 0), длинная сторона вдоль X. Номинальный контур (по стенам, без свеса и веранды — они выходят за контур не больше чем на 1,5 м): rondavel — диаметр 5 м, конёк ≈ 5 м; tin_house — 8 × 6 м, стены 2,6…3 м; stilt_house — 8 × 6 м, сваи 1,2…1,8 м. Расстановка масштабирует X/Z под контур OSM, Y — средним масштабом X/Z.
- Материалы: `Wall_<name>`, `Roof_<name>` (+ необязательный `Wood_<name>`), StandardMaterial3D; текстуры процедурные, ≤ 256 × 256, импорт Godot — сжатие VRAM + мипмапы (как у деревьев). Цвет экземпляра (палитра стен профиля) умножается на альбедо — текстуры светлые, нейтральные по тону стен.
- Превью для шлюза: `/home/greg/deltaplan/build/screenshots/regional-veg/models/houses/<name>/` (вид сбоку и сверху под 45°).
- Расстановка (RV-10): реестр `configs/world_objects.json → buildings.models{name: {path, size_m: [x, z]}}`; профиль `buildings.village_models: [{name, weight}]` и `buildings.village_model_share` (0…1, по умолчанию 0) — доля деревенских домов (VILLAGE, без высоты из OSM), которые рисуются моделью вместо коробки; выбор по хешу позиции дома (детерминированно). LOD0 до 250 м, LOD1 до 1500 м, LOD2 дальше (до `visibility_m`). Без ключей (share 0) — дома как до правки.
