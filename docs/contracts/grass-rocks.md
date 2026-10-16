---
type: "contract"
status: "active"
module: "grass-rocks"
area: "world"
updated: "2026-10-15"
summary: "Камни rocks.glb (G1), интерфейс GrassField и пресеты (G2), протокол замера (G3), режим средней дистанции травы (G4)."
related: ["docs/plan/grass-rocks.md", "docs/perf/frame_profile.md"]
contracts: [{"id": "G1", "version": 1}, {"id": "G2", "version": 2}, {"id": "G3", "version": 2}, {"id": "G4", "version": 5}]
---
# Контракты модуля grass-rocks

Владелец всех — координатор grass-rocks. Контрактные тесты — `tests/contracts/test_grass_rocks_contracts.gd`
(фильтр `grass_rocks_contracts`); меняются только вместе с контрактом (версия +1, через координатора).

## G1. Модели камней rocks.glb — версия 1

- Владелец: GR-4 (`tools/blender/build_rocks.py`). Потребители: `scripts/terrain/rock_scatter.gd`
  (`RockScatter.load_meshes`), `tests/terrain/test_rocks.gd`.
- Файл: `assets/models/rocks/rocks.glb` (путь — `configs/world.json → rocks.model_path`); исходник
  `assets/source/rocks/rocks.blend`. Сборка: `blender --background --python tools/blender/build_rocks.py` (Blender 4.3).
- Варианты — ровно списки `configs/world.json → rocks.boulders` (крупные: boulder0, chunk0, chunk1,
  slab0, slab1, wedge0, tooth0, comb0, comb1) и `rocks.stones` (мелкие: pebble0, chip0, flake0, wedge1).
- У каждого варианта три ноды `MeshInstance3D` с именами `<вариант>_LOD0`, `_LOD1`, `_LOD2` (поиск
  `find_child` по всему дереву). Меш — одна поверхность, есть нормали; UV не обязательны (цвет трипланарный).
- Оси и размер LOD0 (как сейчас): +Y вверх (Godot), наибольший горизонтальный размер = 1 м ± 2 % (у comb —
  вдоль X), низ на −0,15·высоты (± 0,02 м) — камень «врос»; центр по X/Z у начала координат (± 0,1 м). LOD1/2 — та же форма (сейчас расходятся до −60 % у мелких; согласовать — приёмка GR-4).
- Треугольники LOD: LOD2 ≤ LOD1 ≤ LOD0 (равенство разрешено — один LOD в трёх нодах).
  Бюджеты формы — в приёмке GR-4, не в контракте.
- Нет файла или ноды — `load_meshes` даёт пустой меш, вариант пропускается (как сейчас).

## G2. Открытый интерфейс травы — версия 2

- Владелец: задачи травы (GR-3, GR-6, GR-7, GR-8). Потребители: `scripts/terrain/terrain.gd`,
  `scripts/game/world_link.gd`, `scripts/audio/grass_rustle.gd`, `scripts/terrain/tree_crosses.gd`,
  `scripts/ui/settings_panel.gd`, тесты `tests/vegetation/test_grass_field.gd`, `tests/flight/test_sky_shade_grass*.gd`,
  `tests/ui/test_grass_density.gd`, `tests/audio/test_grass_rustle.gd`.
- Класс `GrassField` (`scripts/terrain/grass_field.gd`, extends Node3D). Методы, которые зовут снаружи — сигнатуры не менять:
  - `setup(layer: HeightLayer, height_tex: Texture2D, surface: SurfaceLayer, surface_tex: Texture2D, look: Dictionary, cfg: Dictionary, mowed_spots: Array[Vector4]) -> void`;
  - `set_relief(relief: TerrainRelief) -> void`;
  - `set_landing_sites(sites: Array[Dictionary]) -> void` — скошенные посадочные площадки;
  - `set_trample_mask(img: Image, origin: Vector2, cell_m: float) -> void` — маска примятой травы у старта (R8; `null` — снять);
  - `height_at(x: float, z: float) -> float` — высота травы под точкой, м (шорох); 0 — травы нет;
  - `materials() -> Array[ShaderMaterial]` — все материалы травы (для тени облаков и scene_look);
  - `apply_scene_look(sl: Dictionary) -> void`;
  - статические: `is_enabled(grass_cfg) -> bool`, `density_k(grass_cfg) -> float` (= `density_pct`/100, ≥ 0),
    `ring_offsets(spacing: float, inner: float, outer: float) -> PackedVector2Array` (его использует `tree_crosses.gd`).
- Конфиг `configs/vegetation.json → grass`: ключи `enabled`, `density_pct`, `density_range_pct`, `density_step_pct`
  сохраняются; `density_pct = 0` — травы нет (узел не создаётся); прочие ключи задачи меняют свободно.
- v2 (2026-10-16, GR-25): отладочная переменная окружения `DP_GRASS_DENSITY=<pct>` (для кадров и замеров) сильнее `density_pct` в `density_k`/`is_enabled`; `0` — травы нет. Трава не растёт там, где шейдер рельефа рисует камень, осыпь или голый грунт: одно правило для ближних травинок, слоёв, карточек и `height_at` (CPU).
- Пресеты (`configs/game.json`): low — `density_pct` 0, medium — 100, high — 150.
- Поведение, которое сохраняется: приминание у пилота (press), примятая трава у старта, скошенные места
  (`mowed_spots`) и посадочные площадки, сезон, трава под пологом леса, тень облаков на траве.

## G3. Протокол замера травы и камней — версия 2

- Владелец: координатор. Потребители: GR-2, GR-4, GR-5, GR-7, GR-9, GR-11.
- v2 (2026-10-15): опыт `nocrosses` (кресты деревьев, класс `TreeCrosses`) в `tools/bench/frame_profile.gd`; для задач деревьев список опытов — `base,nocrosses,noimpostors,base2`.
- Машина: RTX 4070 SUPER, дисплей `DISPLAY=:0`, 1920×1080 полноэкранно. Под замком GPU, в своей копии:
  ```bash
  /home/greg/deltaplan/.dpcli/dpcli job --lock gpu start <ID>-perf 3600 env SKIP_FLY=1 TAG_SUFFIX=_noclouds \
    tools/bench/frame_profile.sh build/perf/<ID> "medium high" ongudai \
    --sample=2 --keep=nocloudfx --exps=base,nograss,noscatter,base2
  /home/greg/deltaplan/.dpcli/dpcli job wait <ID>-perf
  ```
  Отметки — по умолчанию `MARKS="2:cockpit 30:chase 60:chase"` (те же, что в `docs/perf/frame_profile/measurements.md`).
- Величины (GPU окна, мс, на каждую отметку и среднее по отметкам): `base` (кадр без облаков);
  **цена травы** = base − nograss; **камни и кусты** = base − noscatter; **кресты** = base − nocrosses; **импостеры** = base − noimpostors; шум = |base2 − base|.
  Примитивов на кадре (монитор `primitives`) для base и nograss.
- Годен, если шум ≤ 0,1 мс на каждой отметке; иначе повторить прогон (один раз), в отчёт — оба.
- Итог — раздел `## <ID>` в `docs/perf/grass_rocks.md`: таблица «пресет × отметка: base, трава, камни+кусты, шум, примитивы, млн»
  и строка «среднее»; данные — `docs/perf/data/grass_rocks_<ID>.tar.gz` (jsonl + report.md, без xdg_* и логов).
  Таблицы — `python3 tools/bench/frame_profile_report.py build/perf/<ID>`.
- Сравнение «до/после» — с разделом `## GR-2` (база) того же документа.

## G4. Режим средней дистанции травы — версия 5

- v2 (2026-10-15, Q2): выбран shell; режим cards удалён; по умолчанию — `"shell"`.
- v3 (2026-10-15, прототип пользователя): режим `"terrain"` — средней дистанции как геометрии нет: ближние травинки (до `grass.radius_m`) как во всех режимах, дальше «трава по высоте травы» рисует шейдер рельефа (зернистость ворса, тёмные щели, светлые кончики; амплитуда и тон — по высоте травы класса поверхности и сезону; шум в мировых координатах 2–3 масштабов с затуханием против мерцания; сочетается с полосами ветра SL-15). Владелец режима — GR-20. Включение в рельефе — uniform материала рельефа, который ставит трава (`GrassField`) только в режиме terrain; травы нет (`density_pct = 0`, low) — деталь выключена. Кольца нет по построению (тот же шейдер).
- v4 (2026-10-15, идея пользователя): режим `"angle"` — слои shell и карточки-пучки по углу взгляда к рельефу: α = asin(|dot(view_dir, n_рельефа)|); α < `grass.mid.card_angle_full_deg` (15°) — только карточки, α > `grass.mid.card_angle_none_deg` (30°) — только слои, между — растворение по шуму экрана/альфе без шва; карточки за порогом выбрасываются в вершинном шейдере целым пучком до выборок; слои в зоне карточек гаснут по альфе/плотности; цвет карточек = цвет луга рельефа, как у слоёв. Ключи карточек — `grass.mid.cards` (возвращены из `archive/grass-cards`). Владелец режима — GR-21. Режим по умолчанию остаётся `shell` до решения пользователя.
- v5 (2026-10-15, Q3): режим по умолчанию — `"angle"`; `shell` и `blades` — через конфиг или `DP_GRASS_MID`.
- Владелец: GR-8 (бывш. GR-16; правит и контрактный тест `test_g4_*`). Потребители: GR-9 (замер), `tools/shots/grass_look.sh`.
- Режим: `configs/vegetation.json → grass.mid.mode` — `"angle"` (слои + карточки по углу, по умолчанию с v5), `"shell"` (только слои), `"terrain"` (v3, прототип в ветке grass-rocks/GR-20, в main нет) или `"blades"` (старый вид: среднее кольцо травинками и дальнее кольцо — для сравнения и замеров).
- Переопределение для кадров и замеров: переменная окружения `DP_GRASS_MID=blades|shell|angle` (читается при `GrassField.setup`, сильнее конфига); неизвестное значение (в том числе `cards`) — как конфиг.
- Статический `GrassField.mid_mode(grass_cfg: Dictionary) -> String` — итоговый режим с учётом переменной окружения.
- Узлы средней дистанции — потомки узла `GrassField` (опыт `nograss` прячет всю траву); в режимах `shell`, `angle` (и `terrain`) дальнее кольцо (26–115 м) травинками не строится — дальше луг рисует шейдер рельефа.
- Цвет слоёв shell = цвет луга рельефа в той же точке (сезон, сухость, пятна, под пологом); внешний край растворяется в луг рельефа по яркости и цвету без видимого кольца сбоку и сверху; стык с ближними травинками — плавный.
- Ближнее кольцо (до ~10–14 м) — одно во всех режимах; границы — `grass.radius_m` и `grass.mid.inner_radius_m`/`outer_radius_m` (м).
- Сохраняется всё из G2 (приминание, маска старта, скошенное, площадки, сезон, лес, густота: `density_pct = 0` — нет и средней травы), ранний выход вне кадра — в любом режиме.
