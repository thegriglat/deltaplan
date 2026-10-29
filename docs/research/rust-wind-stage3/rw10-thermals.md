---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-8a: разбор RW-10 (термики, фон, AirThermals, ядра): исходники, жизнь термика, петля с облаками, разбиение на 4 подзадачи."
conclusion: "~2 550 строк GD + ~150 на стороне; термики — чистые функции (клетка, цикл), но связаны с облаками петлёй (тень, подсос); разбить на 10b–10e"
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3-path.md", "docs/research/rust-wind-stage3/godot-compat.md", "docs/research/rust-wind-stage3/fixtures.md", "docs/research/thermals.md"]
---

# RW-10: термики и фоновое опускание (RW-8a)

Строки — `scripts/atmosphere/…` (`feature/rust-wind`, 2026-10-29). Оценки объёма — по чтению кода.

## Исходники

| файл | строк | что |
|---|---|---|
| `thermal_field.gd` | 1241 | жизнь динамических термиков по клеткам (`_gen_cell` 607, `_ensure` 632, `_spawn` 691, `_set_life` 762, `_cell_params` 349, `_mix` 367), улицы (`_street_for` 195), снос и наклон (`_apply_wind` 265), статичные (`add_static` 285), Cb (`_setup_cb` 817), тень облаков на источнике (`_cloud_shade_at` 832), обновление порциями (`begin_refresh` 406, `step_refresh` 444, `_job_*` 479–597, бакеты `_rebuild_buckets` 1080), асинхронная сборка источников поля (`AirJob` 865, `_air_launch` 921), опрос `sample` 1165, `near` 1231 |
| `air_model/air_thermals.gd` | 1152 | источники термиков **из поля**: `build` 189 (столбцы Φ, w*, потолок, плотность Аллена, выбор источников по убыванию Φ, водосборы, параметры), `_cols_band` 552, `_pick_band` 704, `_owner_band` 716, `_src_band` 774, `fill` 892, `with_between` 912 («между» пузырями), `pick_in_column` 997, `land_fraction` 952, `expected_up/net` 1045/1051 |
| `atmo_thermal.gd` | 151 | запись термика, огибающая роста/распада 89, `update_time` 101, снос 75, ось 133 |
| `atmosphere.gd` | ≈ 140 | фон: сумма `fade·(bg_sink·(1 − маска) + th.x)` (`:951–954`); `set_static_thermals` 1716; `cores` 2139; `thermals_near` 1335; `refresh/step` 864–915; `_cloudbase` 815 |
| `terrain/terrain.gd` | ≈ 120 | `thermal_source_strength_water` 744 + `_edge_proximity` 776 + `_surface_class` 1056 — **сила источника 0..1** (`sun_fn` у `GroundField` и `AtmoDay.source_fn`) |
| `atmo_day.gd`, `surface_heating.gd` | 113, 98 | `source_at(x, z, t)`, направления солнца по классам — часть RW-12; `SurfaceHeating` в крейте есть |

Итого GD ≈ **2 550** строк (+ ≈ 260 на стороне Terrain и фасада). Rust: ≈ 3 200–3 600 (оценка).

## Как это устроено (что переносить)

1. **Два пути рождения термика** (`_spawn` / `_spawn_air`):
   - **сетка клеток** — когда поля нет (`air_model.enabled = off`, загрузка, `Failed`, синтетика): мир разбит на клетки `thermal_spacing_m`, повёрнутые по ветру (ось `a` по ветру); у клетки период 630–1560 с (сумма границ диапазонов `gap/grow/mature/decay` из `thermal.*`) и фаза; в цикле термик рождается, если `rng.randf() ≤ thermal_duty` и лучшая из `source_candidates = 8` точек клетки освещена (`sun_fn` ≥ `sun_min 0,35`, не вода), с подтяжкой к «улице»; сила `lerp(smin, smax, u^1,4)`, радиус, жизнь, Cb (`cb_thermal_chance`), «очень сильный» (8–9 м/с);
   - **источники из поля** (`ia ≥ 2¹⁹`, столбец j, ряд i): точка/сила/потолок/снос/кольцо — из `AirThermals` (строится по **самому грубому уровню** `air.levels[last]` = область 400 м, `thermal_field.gd:907`), остальное — как у клетки; клетки сетки в зоне покрытия поля (`air_src.covers`, вес края ≥ ½) термиков не рождают.
2. **Состояние** — чистая функция `(клетка, цикл, t)`: id = `_mix(ia, ic, cy)`, сид RNG = id, погода/солнце/кромка/тень — на момент рождения (`_env_at` 654 через `AtmoDay`). Что материализуется — зависит от фокуса (круг генерации 20 км, физики 6 км — `thermal.generation_radius_m`, `physics_radius_m`); память о пустых циклах (`_empty_cycles`) и обойдённых клетках (`_cell_seen`) — кеши, не физика. `start_at(t)` равен прогону с 0 (W2).
3. **Опрос** (`sample` 1165): бакеты 500 м → термики в бакете; профиль по радиусу (Гедеон, радиус по высоте — Аллен `ξ^⅓(1 − 0,25ξ)/0,75`), по высоте (`ground_ramp_m`, `top_taper_m`), подсос под основанием (`suck_depth_m 250`), в облаке (`in_cloud_mean_frac 0,25`), оторвавшийся низ на распаде (`cut_h`, плавная граница 60 м), σ края (`edge_factor 0,35`, `edge_width 0,45`); результат `(w, маска, σ_края)`; с полем — `with_between`: «между» = `w_conv` поля − ожидаемый чистый поток пузырей (`air_src.expected_net`).
4. **Фон** (`bg_sink`, `background_sink_ms`): `w = fade(agl/60 м)·(bg_sink·(1 − маска) + w_термики)`; в зоне поля `маска` растёт до `маска + (1 − маска)·доля_поля` (`with_between`).

## Входы

Конфиг `thermal.*` (≈ 50 ключей), `ground_fade_m 60`, `air_model.*` (покрытие); погода дня (`thermal_strength_ms`, `thermal_radius_m`, `thermal_spacing_m`, `thermal_duty`, `sky_duty_k`, `thermal_extreme_*`, `cb_*`, `cloud_depth_m`, `overdevelopment_chance`, `cloud_size_factor`, `street_strength`, `background_sink_ms`, `convective_turbulence_ms`, `dry_thermal_fraction`) — выводит RW-12; солнце (`AtmoDay.sun_at` или `set_sun_direction`), `insolation` (перистая пелена); поле (RW-6, `Field::raw_*` — уже отдаются: `wind_field.rs:815–860`): `hc, k1, w_conv, θ′, vel`, мета `heat, z_i, z_i_col, gam, z0` (`FieldMeta`, `wind_field.rs:73–86`; `u10` AirThermals берёт из `level.meta` GD — в `FieldMeta` его нет, добавить); место: высота, вода (`is_water`: класс WATER или море по высоте ≤ 0,5 м), сила источника (растры `cls`, `moist`, нормаль из высот); сид мира; фокусы (`set_focuses`), статические термики (`set_static_thermals`), время.

## Выходы

- Слагаемые W7 `thermal` (и вертикаль «между»), маска ядра и σ края (идут в RW-8 и сумму σ).
- **Описания W6** `cores(center, radius)`, шаг 15: `id, flags, x, z, y_src, top, w, radius, lean_x, lean_z, age_s, life_s, stage, vis_seed, storm` — собирается в `atmosphere.gd:2139` из термиков в радиусе физики вокруг фокуса (`_active`; W6 v3, «охват») — **в крейте охват задаст его окно** (по фокусам).
- Метод фасада `thermals_near` (`atmosphere.gd:1335`, старое; потребители — тесты, `world_link`, птицы) → через `cores`.
- Для RW-11: список термиков с `is_cb`, `has_cloud`, `strength`, `top`, `t_birth/t_grow/t_mature/t_decay`, `lean`, `drift_vel` — внутренний вход гроз (`StormField.refresh`) и облаков.

## Случайность

`RandomNumberGenerator` везде (сид — id или `_mix`; порядок `randf` в `_spawn` и в `fill` значим: порядок вызовов определяет, какое число какой величине достаётся — **копировать порядок буквально**), `hash(Vector3i)` в `pick_in_column`, `hash(Vector2i)` у статичных (только `vis_seed`). Порт PCG32/`hash` — шлюз в `godot-compat.md`.

## Что уже есть в крейте

Каналы поля для `AirThermals` (`raw_*`, мета, `gauss2d` — `place_input.rs:150`, `zi_columns`), `SurfaceHeating` (направления солнца и ночь застройки — `surface_heat.rs:381,396`), `mix_flux` (`:256`, поток тепла по классу/нормали/влажности/небу/воде), `solar_position` (`sun.rs:34`), `ground_height`, `thermal` — `Field::z_i`, `heat`; `FieldSet::sample_w_conv/sample_theta` (`field_set.rs:210,215`). **Нет:** вся жизнь термика, `AirThermals.build`, `thermal_source_strength` (нормаль, лесная/водная маски, правило скал `rock_slope_deg 38°`, близость границ классов `edge_boost`), бакеты, `cores`, фокусы.

## Эталоны

Все 11 случаев (термики есть в 94–100 % точек-моментов). Сетка клеток — `synth_*` (два случая со статичным термиком), источники поля — `ongudai_*` (`thermal` до 9,5 м/с в `ongudai_strong`). Ядра: `desc.json` на каждый момент (шаг 15). **Подсос и тень облаков:** термики с облаком в `thermal` и в силе источника (`_cloud_shade_at`) не воспроизвести без RW-11; отделить их в эталоне нельзя → сверка `thermal` в точках `above_base` и в 250 м под основанием — только после RW-11 (см. «Порядок»). Ядра в дневных случаях — зависят от `AtmoDay` (RW-12): RW-10 сначала на пресетных случаях (`day == null`).

## Тесты GDScript → cargo

`test_air_thermals.gd` (644 строки, 11 функций: источники над прогретым, в схождении, не в тени, потолок по инверсии и кромке, поток массы пузырей = потоку поля, маска ведущего, атмосфера с полем), `test_air_thermals_parallel.gd` (полосы `build` дают побитно то же, что последовательно — в крейте: `par_iter` против одного потока), `test_air_thermals_relief.gd` (FL-17: влажность ложбин → точка и сила источника), `test_subsidence.gd` (CLF-10: компенсирующее опускание, сглаживание гауссом), `test_atmosphere.gd` (профиль термика, снос, жизненный цикл, фон), `test_clouds_and_generation.gd` (статичные из конфига, улицы, отрыв низа), `test_pilot_words.gd` (слова пилота в числах), `test_calibration.gd` (сила по дням, источники на триггерах — частично T9), `test_decompose_terms.gd`; бот-тесты (`test_ridge_starts`, `test_xc_bot`) — T9.

## Разбиение (предложение)

| подзадача | что | зависит | GD строк | параллельно |
|---|---|---|---|---|
| **RW-10b** | `AtmoThermal`, жизнь по клеткам (аналитический путь), статичные, `sample`, фон, `cores` для сетки; без облачных зацепок (`suck = th.suck`, тень = 0) | каркас 8b (PCG32/хеш — 8c), ветровая рамка (RW-9: `vec2_at`, `dir`), погода (preset) | ≈ 900 | с 10c, 10d |
| **RW-10c** | `thermal_source_strength` из растров места + `AtmoDay.source_fn` (час, вода, ночь) | `mix_flux`, `SurfaceHeating` (есть) | ≈ 250 | с 10b, 10d |
| **RW-10d** | `AirThermals.build` целиком (столбцы, плотность, выбор, водосборы, `expected_net`, `pick_in_column`, `land_fraction`, `fill`) | поле RW-6 (есть), 10c (`pick_fn`), PCG32/хеш | ≈ 1 150 | с 10b, 10c |
| **RW-10e** | источники поля в жизни термика (`_spawn_air`, `_air_launch`, пересборка по ключу, «между», охват `covers`), `cores` с охватом по фокусам | 10b, 10d | ≈ 450 | после 10b + 10d |

Сумма — 10b…10e ≈ 2 750 строк GD. После RW-11 — замыкание петли (подсос, тень), повторная сверка (карточка «10f» в `cards.md`).

## Риски

1. **Петля термики ↔ облака.** `ThermalField.sample` берёт `cloud_phys.suck(th)` (`:1146`), источник — `_cloud_shade_at` (`:832`, `CloudField.shade_at`); `CloudFieldSources.prepare` берёт `AirThermals` (`carried`, Φ) и живые термики. Решение для RW-10: крейтовые «крючки» (`suck`, `shade`) с нулевой реализацией; RW-11 включает; T1 `thermal` с облаками — после RW-11.
2. **Дискретные решения.** `floori((t + phase)/period)`, пороги `sun_min`, выбор ближайшего источника водосбора, порядок сортировки по Φ (равенство — по номеру) — разница в f32/f64 может дать единичное расхождение числа ядер при допуске W8 «число равно». Предложение: W8 v2 — допуск числа ядер «≤ 3 % и не больше 2 ядер на момент в случае», с перечнем расхождений в отчёте (подгонять реализацию под фикстуру нельзя).
3. **Сила источника.** GD берёт класс из слоёв 10 м (вода — канал G маски ≥ 0,5, лес — R ≥ 0,5, поляны) и нормаль на шаге слоя; растр W5 — 25 м (`cls`, `moist` u8). Источники у кромки леса/воды сдвинутся. Мерки нет — вопрос на RW-10c (замерить долю столбцов, у которых сила отличается > 0,05, на Онгудае).
4. **Конфигов не хватает:** `world.json` (`terrain_look.rock_slope_deg`, `surface.thermal.edge_*`, `time.*`) вне списка имён `configure` (W5) — см. «Пробелы контракта».
5. **Пересборка источников** в GD ~0,4–0,6 с на главном потоке (`clipmap.md`); в крейте — фон (rayon), публикация целиком; ключ пересборки — кромка, `thermal_duty`, солнце (`_air_inputs`, `:981`) — меняется в ходе дня каждые `quantum_h`: частота пересборок в крейте надо ограничить (вопрос, не измерялось).
6. **Статичные термики** (`set_static_thermals`, режим `dynamic|static|both`) — отдельный путь (`add_static`, id < 0).
