---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-8a: подробный разбор RW-11 (_extra_flow: гроза, волны и роторы, выброс из облака) и граница «физика облаков в крейте, отрисовка в Godot»."
conclusion: "Физика (CloudField, подсос, Cb-объекты, гроза, волна) — в крейт; выбор и затухание для рисования, слоты и шейдеры — Godot по расширенной записи Cb (W6 v4)"
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3-path.md", "docs/research/rust-wind-stage3/fixtures.md", "docs/research/cloud_field.md", "docs/contracts/rust-wind/descriptions.md"]
---

# RW-11: `_extra_flow` и граница облаков (RW-8a)

Строки — `scripts/atmosphere/…` (`feature/rust-wind`, 2026-10-29). Объём — по чтению кода.

## Исходники

| файл | строк | что |
|---|---|---|
| `storm_field.gd` | 118 | гроза: нисходящий поток, растекание, фронт порывов; `sample` 78, `intensity` 60, `storm_start` 55 |
| `wave_field.gd` | 198 | подветренные волны/роторы: поле η, ∂η/∂x, высота гребня на сетке 300 м (кусками 8 × 8), `_build` 170 (24 пробы против ветра), `sample` 111, `crests` 136 |
| `cloud_physics.gd` | 517 | Cb-объекты (сетка по `clouds.width_max_m 3000`), подсос `suck` 137, `sample` 481 (плотность и направление к краю), `density_at` 472, `visible_clouds` 431, шаг поля в рабочем потоке (`_refresh_field` 231, `FieldJob` 64), снимок К4 (сеть) |
| `cloud_field.gd` | 472 | поле облачности региона 96 × 96 × 400 м: `reset` 169 (разгон `spinup_s 2400`), `step_to` 187, `_step` 213 (da/dt, dp/dt, dd/dt, башни), `_advect` 304 (полулагранжев снос), `sample` 405, `density_at` 420, `shade_at` 431 |
| `cloud_field_sources.gd` | 220 | входы поля по столбцам: `prepare` 29 (a_u, D*, снос, рельеф; три источника подъёма — конвекция `AirThermals`, склон `WindField`, аналитика) |
| `cloud_model.gd` | 321 | Cb-объекты: `stage` 54, `_life_window` 75, `size` 122, `center` 117 — **физика**; `life_fade` 86, `range_fade` 98, `far_m` 103, `step_fade` 110, `select*`, `merge_winners`, `drop_*` — **выбор для рисования** |
| `cloud_field_codec.gd` | 107 | текстура (К2) и снимок для сети (К4) |
| `atmosphere.gd` | ≈ 170 | `_extra_flow` 1001, `cloud_density_many` 2081, `clouds` 2183, `cloud_raster` 2236, `wave_crests` 2286, `_update_wave_wind` 1312 |

Итого физика ≈ **1 550** строк GD (без кодека, без выбора и без `cloud_layer.gd`); Rust ≈ 1 900–2 200 (оценка). Выбор для рисования (≈ 160 строк `cloud_model.gd`) и `cloud_layer.gd` (52 КБ, ≈ 1 250 строк) остаются в Godot, но перелицовываются на записи W6.

## Что считает каждое слагаемое в сумме (`_extra_flow`, `atmosphere.gd:1001`)

- **storm** (`T_STORM`): по грозовым ячейкам (термики `is_cb`, `StormField.refresh` 46) — `Vector4(vx, vy, vz, σ)`: `−7,0·e·exp(−r²/rd²)·smoothstep(agl/350)` вниз под основанием; растекание `13·e·exp(−agl/600)·radial` от центра облака; фронт порывов `+2,0·e·exp(−((r−rf)/900)²)·…`; горизонталь ≤ `outflow_ms`; `vy ∈ [−7, 2]`; σ = `0,35·13·e·(front + 0,5·radial)·prof` → в `_storm_turb`. Радиус ливня `rd = cloud_width_per_ms·strength·0,5·0,45`, где `cloud_width_per_ms` = `clouds.width_per_ms_m 700` × `cloud_size_factor` погоды.
- **wave** (`T_WAVE`): `w = clamp(wave_strength·gain·u·∂η/∂x·prof, ±8)`, `u` — ветер на `wind_reference_agl_m` (`speed_at(1000)`); ротор σ под гребнем волны; длина волны `λ = 2π·u/N` (N из погоды `stability_n_per_s`), кеш сбрасывается при смене λ или направления.
- **cloud** (`T_CLOUD`): в облаке горизонталь `3,0·плотность·(направление к краю)`; `_cin.x` (плотность) → бурление `in_cloud_turb 3,5` в сумме σ.

## Входы

- Конфиг: `storm.*` (≈ 15 ключей), `wave.*` (≈ 25), `thermal.suck_*`, `thermal.cloud_cover_min`, `clouds.*` (модель Cb: ширины, `height_to_width`, `delay_factor`, `grow_s`, `linger_s`, `overdev_*`, `cb_*`), `cloud_field.*` (≈ 30).
- Погода (RW-12): `wave_strength`, `stability_n_per_s`, `cloudbase_agl_m`, `_derived.z_lcl_msl_m` (основание поля), `cloud_depth_m`, `overdevelopment_chance`, `cb_chance`, `cb_thermal_chance`, `cb_top_above_base_m`, `cloud_size_factor`, `cirrus_cover` (тень и `sun_block_cover`), `lens_level_above_crest_m`.
- Из RW-10: живые термики (`is_cb`, `has_cloud`, сила, верх, времена жизни, снос), источники поля (`AirThermals.carried`, Φ, `col_zi`, `land`), `cloudbase_msl`; из поля: `hc`, `w_mech`, `w_conv`, `θ′`, `vel` на высоте основания; из RW-9: `GroundField.height` (волны), профиль ветра (снос поля, `wind_at`).
- Сид (башни переразвития, `hash(Vector2i(c, seed))`), время (шаг поля `step_s = 20 с`, на сетке времени).

## Выходы

- Слагаемые W7 `storm`, `wave`, `cloud` + σ для RW-8.
- **Описания W6:** `clouds(center, radius)` (облака поля из `visible_clouds` + Cb, шаг 10), `cloud_raster()` (растр 96 × 96: `cover, depth, stage, activity, bg_cover, bg_depth`, оси W1, строки — к +Z), `cloud_raster_version`, `wave_crests(...)` (шаг 4), `cloud_density_many`, `cloudbase_msl`.
- Видимое пилоту: облака рисует `CloudLayer` (compute-проход + карта теней) по текстуре поля и записям Cb/линз/шапки/роторов.

## Состояние во времени

- **Поле облаков** — единственное по-настоящему прогностическое состояние слагаемых ветра: `da/dt, dp/dt, dd/dt, d(od)/dt` на 9 216 столбцах, шаг 20 с, при `start_at(t)` — разгон 2 400 с (120 шагов). Назад по времени и скачок > 2 400 с — `reset`. Снос — когда накоплено `advect_cells` клеток. Входы подмешиваются за `input_blend_s 60 с`. Результат при равных входах и t — побитно один (комментарий в `cloud_field.gd:17–19`).
- **Cb-объекты** и **гроза** — функции жизни термика (чистые по `t`), без истории.
- **Волны** — кеш кусков (производный, чистый).
- `CloudLayer` хранит историю кадров (`_hist`, `_cnt`, `_sel`, слоты) — это вид, не воздух; но `_sync_history` вызывает `model.merge_winners(...)` для **прошлых** моментов `k·interval` (`cloud_layer.gd:882`) — нужен прошлый `t` (см. «Пробелы»).

## Случайность

Своего RNG нет; `hash(Vector2i(c, seed))` (`cloud_field.gd:209`) — отбор столбцов башен; термики несут RNG (RW-10). Шум для облаков — шейдеры (не переносятся).

## Что уже есть в крейте

Поле и уровни; `weather_core::day` (`z_i`, `theta`); `Field::raw_*`. Нет ничего из облаков, гроз, волн. `Formula::clouds/cloud_raster/wave_crests/cloud_density_many/cloudbase_msl` — заглушки (`formula.rs:1177–1219`). Типы `Cloud`, `Crest`, `Raster` определены (W4 v2).

## Граница «физика — в крейте, отрисовка — в Godot» (рекомендация)

| часть | где | довод |
|---|---|---|
| `CloudField`, `CloudFieldSources`, `CloudPhysics` (Cb-объекты, подсос, плотность, `sample`, `shade_at`) | **крейт** | входит в сумму ветра (`_extra_flow`, подсос в `thermal`, тень на источниках) |
| `CloudModel.stage/size/center/_life_window` | **крейт** | функции жизни Cb-термика; нужны подсосу и описаниям |
| `StormField`, `WaveField` | **крейт** | слагаемые ветра; `crests` — описание W6 |
| `CloudModel.select*`, `merge_winners`, `drop_*`, `life_fade`, `range_fade`, `far_m`, `step_fade` | **Godot** | зависят от камеры, `max_clouds`, гистерезиса кадров, слотов рисования — вид, а не воздух; физика от них не зависит |
| `CloudFieldCodec.to_image` (текстура К2) | **Godot** по `cloud_raster()` | картинка |
| `CloudFieldCodec.snapshot/apply_snapshot` (К4, сеть) | не переносить | сеть не важна (решение 2026-10-25); `Net`-подтяжка в `FieldJob` — не переносить |
| `CloudLayer`, шейдеры, карта теней, птицы, пыль | **Godot** | рисование |

Для рисования Godot'у нужны только записи W6 + `cloud_raster()`. **Что у `CloudLayer` сейчас идёт мимо фасада** (`atmo.field.thermals`, `atmo.cloud_phys.model`, `atmo.storm.intensity/storm_start`, `atmo.wave`): поля Cb — `id, src (x, y, z), top, is_static, noise_seed, drift_start, drift_at(t)` + `stage/size/center/life_fade`, `storm_start`, `storm.intensity`; для волн — `enabled`, `crests`. Их надо дать записью (W6 v4, «Пробелы контракта»), без этого `cloud_layer.gd` не отвязать от `ThermalField` и RW-13/T7 (тест чистоты) красный.

## Эталоны

`synth_storm` (гроза: 182 точки-момента `storm`, σ до 4 м/с), `ongudai_day_2` (10), `synth_wave`, `ongudai_wave` (144 точки-момента `wave` до 8 м/с); `cloud` — 6–33 точки-момента в шести случаях; `desc.json`: `clouds` (шаг 10; флаг 4 — Cb, `id = 100000 + id ядра`), `crests` (шаг 4). Нужны дополнительные случаи (RW-2c): гроза на Онгудае с полем, Cb с `cloud_raster`, облако поля над ядром (подсос).

## Тесты GDScript → cargo

`test_cloud_field.gd` (315 строк, 10 функций: источник подъёма до LCL, инварианты, детерминизм, аналитический путь, задержка таяния, снос, слабый < сильный), `test_cloud_field_runtime.gd` (поле в симуляции, результат потока = синхронному), `test_cloud_start.gd` (CLF-12: разгон `start_at`), `test_cloud_suck.gd` (подсос, `cloud_density_at`, болтанка в облаке), `test_clouds_and_generation.gd` (Cb, тень поля, улицы, статичные), `test_storm_rarity.gd` (грозы редкие: частота Cb по температуре), `test_hazards.gd` (пелена, Cb, волны), `test_wave.gd` (подъём и лентикуляры в одном месте). Остаются в GDScript (рисование): `test_cloud_fade`, `test_cloud_layer_history`, `test_cloud_select_chunked`, `test_cloud_render` (GPU), `test_cloud_shell`, `test_cloud_shape_mask`, `test_cloud_quarter`, `test_sun_transmission`.

## Подзадачи (предложение)

| подзадача | что | зависит | GD строк |
|---|---|---|---|
| **RW-11b** | `WaveField` + `wave_crests` + слагаемое `wave` (лист) | ветровая рамка RW-9 (`wind_reference_agl`), погода | ≈ 250 |
| **RW-11c** | `StormField` + слагаемое `storm`; `CloudModel.stage/size/center` для Cb | 10b (термики `is_cb`) | ≈ 350 |
| **RW-11d** | `CloudField` + `CloudFieldSources` + `CloudPhysics` (подсос, плотность, `sample`, `shade_at`, `cloud_raster`, `clouds`), замыкание крючков RW-10 | 10b, 10d/e (`AirThermals`), RW-12 (LCL, `cloud_depth_m`) | ≈ 1 000 |
| **RW-11e** | W6 v4 + `cloud_layer.gd` на записи Cb/волн/гроз (переход Godot-стороны) | 11c, 11d, решение по `t` в прошлом | ≈ 300 в GD |

## Риски

1. **Петля с RW-10** (подсос и тень облаков — `rw10-thermals.md`, «Риски», п. 1): без RW-11d источники под тенью облака сильнее эталона.
2. **Поле облаков вычисляется заранее** (разгон 2 400 с на `start_at`): стоимость в Rust — порядка 120 шагов × 9 216 столбцов; в игре GD делал в рабочем потоке; бюджет `start_at` в W2 — вопрос, не измерялось.
3. **Прошлое время** у `CloudLayer` (`merge_winners` на `k·interval` назад до `fade_out_s`) — решение: запись `clouds(…)` с моментом `t ≤ now` либо накопление в Godot (предложение — первое: Cb-стадия — чистая функция времени).
4. **Детерминизм потока**: GD — шаг поля порциями в потоке, «в headless ждёт»; крейт — `deterministic` как у поля (W3).
5. **Слабая выборка** эталонов (одна гроза, одна волна): добавить RW-2c.
