---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-8a: слагаемые ветра на GDScript → крейт (RW-8…12): сумма air_velocity_at, разбор задач, порядок, пробелы контракта, переход фасада."
conclusion: "≈ 7 500 строк GD в 16 подзадач (≈ 37 дней); первыми каркас суммы и совместимость с Godot; шум и RNG портировать; термики и облака связаны петлёй; фасад — одним шагом в конце"
data: "tests/fixtures/wind/cases/"
applied_in: ""
related: ["docs/plan/rust-wind.md", "docs/contracts/rust-wind.md", "docs/contracts/rust-wind/trait.md", "docs/contracts/rust-wind/descriptions.md", "docs/contracts/rust-wind/dpair.md", "docs/contracts/rust-wind/fixtures-tolerances.md", "docs/research/rust-wind-field-path.md", "docs/research/rust-wind-stage3/rw8-rw9.md", "docs/research/rust-wind-stage3/rw10-thermals.md", "docs/research/rust-wind-stage3/rw11-clouds.md", "docs/research/rust-wind-stage3/rw12-weather.md", "docs/research/rust-wind-stage3/godot-compat.md", "docs/research/rust-wind-stage3/fixtures.md", "docs/research/rust-wind-stage3/cards.md"]
---

# Этап 3: слагаемые ветра GDScript → крейт (RW-8a)

Разбор по чтению кода `feature/rust-wind` на 2026-10-29 (после слияния `810a302`); Godot и `cargo` не запускались, фикстуры читались numpy. «GD» — GDScript игры, «Rust» — `rust/dp-air/src/`. Числа строк и дней — **оценка по чтению**, не замер. Подробности по задачам — `docs/research/rust-wind-stage3/{rw8-rw9,rw10-thermals,rw11-clouds,rw12-weather}.md`, шум и RNG — `godot-compat.md`, покрытие эталонами — `fixtures.md`, проект карточек — `cards.md`.

## Выводы и рекомендации

1. **Сумма ветра — одна функция на ≈ 300 строк** (`Atmosphere.air_velocity_at` 921–988 и `_air_velocity_field` 1071–1213), в которую все слагаемые входят **не слагаемыми, а множителями и квадратами**: болтанка считается последней, по среднему ветру со всеми добавками (гроза, волна, облако), σ складывается квадратами с ограничителями, в полосе края поле и аналитика смешиваются с весом `a`. Раздельный перенос слагаемых возможен только за общим каркасом суммы (п. 3).
2. **Объём: ≈ 7 500 строк GD → ≈ 9 000 Rust, 16 подзадач, ≈ 37 исполнительских дней** (RW-8 ≈ 600, RW-9 ≈ 680, RW-10 ≈ 2 750, RW-11 ≈ 1 550 + 300 в `cloud_layer.gd`, RW-12 ≈ 735, каркас и совместимость ≈ 880). Критический путь при ≤ 4 параллельных — ≈ 18–19 календарных дней.
3. **Сначала каркас (RW-8b) и совместимость с Godot (RW-8c)**, параллельно: каркас переносит в модуль `terms/` точки `formula.rs`, которые правят все (структура `Published`, `sample_point`, заглушки методов трейта), и задаёт слоты слагаемых; дальше `formula.rs` не трогают до итогового шага фасада — иначе пять исполнителей конфликтуют в одном файле.
4. **Шум и RNG — портировать, не заменять** (вопрос 5 плана): рывки слоя смешения — пороговая функция по хвосту распределения симплекс-шума, настроенная с пилотами; побитный порт `FastNoiseLite` (OpenSimplex2S 3D) и PCG32 даёт сверку FULL поточечно (около 1 300 точек-моментов `turb` и 900 `gust`). Шлюз — дамп из Godot и сравнение ≤ 1e-6; не сошлось за день — замена с T3. Хеши `hash(Vector3i/Vector2i)` определяют положение источников термиков и башен Cb — без порта сверка ядер невозможна.
5. **Термики и облака связаны петлёй** (`ThermalField.sample` берёт подсос из `CloudPhysics`, источник — тень поля облаков; поле облаков питается `AirThermals`). RW-10 переносится с нулевыми «крючками» (подсос = `th.suck`, тень = 0); замыкает RW-11d + RW-10f; сверка `thermal` у базы облаков — после них.
6. **RW-12 нужен раньше, чем кажется:** без `derive` и `AtmoDay` нельзя воспроизвести три дневных эталона, а ядра рождаются по погоде **в начале цикла**. До него RW-8…11 идут на условиях вида «эталон» (готовый пресет). Блокер RW-12 — климат места: `loc.climate` (W5 v3) несёт 3 числа и 2 флага из ≈ 10 нужных чисел и 4 флагов (W5 v8).
7. **Граница облаков:** физика (`CloudField`, `CloudPhysics`, Cb-объекты, гроза, волны) — в крейт; выбор для рисования (`select`, `merge_winners`, затухание), слоты, шейдеры — Godot по расширенной записи Cb (W6 v4). `cloud_layer.gd` сейчас — единственный потребитель мимо фасада (`atmo.field.thermals`, `cloud_phys.model`, `storm`, `wave`).
8. **Фасад переключать одним шагом в конце** (RW-12z), по слагаемым — нельзя чисто (п. 1); до того T1 по слагаемым ведётся в `cargo test` против набора RW-2b. Переходная выдача поля `field_export` остаётся до RW-12z.
9. **Эталоны неравномерны:** `turb` — только `ongudai_*`, `storm` и `wave` — по два случая, `air_model.enabled = off` и словарь `derive` не покрыты вовсе — нужны RW-2c (`fixtures.md`).
10. **Контракту нужны правки по 9 пунктам** (раздел «Пробелы контракта»): W5 (`world.json`, климат v8, маски), W6 v4, W8 v2, W2/W4 (поверхностный порыв для `GustDust`, охват фокусов, состав `weather_json`).

## Сумма ветра

`air_velocity_at(pos)` (`atmosphere.gd:921`) → `sample_many` (`:2049`) зовёт её дважды: FULL (`turbulence_enabled = true`, σ = `_last_sigma`) и MEAN (`false`; σ остаётся полной). Нет земли/воздуха (`ground`, `field` пусты) — нули.

**Общее начало (`:925–927`).** `gs = ground.sample(x, z)` → `(h, dh/dx, dh/dz, s)` (`s` — линия тени); `agl = max(y − h, 0)`; `u = speed_ref·профиль(agl)·altitude_factor(y)`. Поле используется, если `_air_on` и доля `a = air_field.sample(...).w > 0` (`:928`).

**Ветка без поля (`a = 0`, `:931–988`).**
1. Подветренная зона: `depth = s − y`; при `depth > −shear_layer (350 м)` и `u > 0` — `lee = clamp((depth + 350)/(40 + 350))·clamp(relief/60)`; `danger = smoothstep(2, 5, U_ref·altitude_factor)` (`_lee_danger` 1215).
2. Склоновый подъём `w_ridge = clamp(0,85·u·slope·exp(−agl_s/250), ±6)` по точке, сдвинутой по ветру на `min(0,8·agl, 400)` (`:990`), × `(1 − lee)`.
3. Термик `th = (w, маска, σ_края)` (RW-10). `fade = min(agl/60, 1)`; `w = fade·(bg_sink·(1 − маска) + th.w) + w_ridge`; `h = u·(1 − 0,6·lee)`; при `lee > 0` добавка `_lee_flow` (1254): опускание `−lerp(0,08; 0,08; danger)·u·lee`, рывки `−1,0·u·hard·g`, обратный поток `−0,65·u·hard·exp(−agl/max(0,6·relief, 1))`, `hard = lee·danger·(1 − H/300)`, H — поток тепла дня из σ конвекции (`_lee_heat_factor` 1232, `heat_kill_wm2 = 300`: нагрев убирает пузырь).
4. `v = (wd.x·h, w, wd.z·h)` + `_extra_flow` (1001): **гроза** (RW-11), **волна** (`wave.sample`), **выброс из облака** `3,0·плотность·(к краю)`.
5. σ (если `turbulence_enabled`): `rot = lerp(0,5; 0,9; danger)·u·lee`; `amp = min(√(mech² + conv² + th.σ² + rot² + σ_гроза² + σ_ротор²), max(4, min(rot, 7)))`, `mech = 0,14·u·(1 + 1,0·exp(−agl/150))`, `conv` — Ленчов по `convective_turbulence_ms`; шум аналитики `gust_unit(pos, t, advect, agl/300)·amp` (вертикаль × 0,7 × `fade`); бурление в облаке `3,5·плотность` квадратом в σ и шумом в `v`.

**Ветка с полем (`a > 0`, `_air_velocity_field` 1071).** Доля поля: уровни от мелкого, вес уровня — `smoothstep(0, 5, d)`, `d` — расстояние до края в клетках (по горизонтали и до верха), остаток идёт следующему (грубому), непокрытое — аналитике: `a = 1 − Π(1 − wᵢ)` (`air_field_set.gd:201`, Rust `field_set.rs:287`); смена поля — подмена за `blend_s = 60 с` (smoothstep по времени атмосферы).
1. `fw = (Σ вклад, w_mech, Σ вклад, a)` — вклады уже со своими весами. Полоса края (`a < 1`): `lee_a`, `w_ridge` — как в аналитике, веса `(1 − a)`.
2. Признак отрыва поля `lee_f` (`FieldTurbulence.lee`, по каналам `T_UOUT, T_AOUT, T_DESC`) и скачок слоя смешения `ΔU = max(U_H − |u_поля|, 0)·lee_f`, `U_H` — ветер поля на высоте гребня (второй опрос, `:1100`).
3. `w = fade·(bg_sink·(1 − маска) + th.w) + fw.w_mech + (1 − a)·w_ridge − (1 − a)·опускание·u·lee_a − burst·hard_a·g`; `h = u·(1 − a)·(1 − 0,6·lee_a) − 0,65·hard_a·exp(...) − a·0,22·U_H·lee_f·danger·unres·exp(...)`, `unres` — доля пузыря отрыва, не разрешённая решателем (`reverse_unresolved`, 1 − smoothstep(4, 8; 2,8·relief/dx)). `v = (fw.x + wd.x·h, w, fw.z + wd.z·h)` + `_extra_flow`.
4. Болтанка (FULL, `:1136–1213`): `σ_u, σ_v, σ_w` из `FieldTurbulence.sigma` (u*, сдвиг, Ri, w*, конвекция σ³-суммой, MIL-HDBK-1797) → максимум с `sep_sigma(ΔU)` → в квадрате прибавляются `th.σ²`, σ_гроза², σ_ротор² (σ_w — ×0,7²) → ограничитель `max(4; min(σ_sep, 7))` → шум `GustSpectrum.sample` с растяжением масштабов у земли → поворот вдоль/поперёк среднего ветра в точке (**включая `_extra_flow`**). В полосе `a < 1`: `tv = (a·tv + (1 − a)·ta)·k`, `k = 1/√(a² + (1 − a)²)`, `σ = √(a·σ_u² + (1 − a)·amp²)`. Бурление в облаке — как в аналитике; `_last_sigma = √(σ² + chaos²)`.

**Ограничители вне суммы:** скорость поля ≤ 40 м/с и `|w| ≤ 10` (при подаче поля, `air_model.max_*`), подъём склона ±6, волна ±8, гроза: горизонталь ≤ 13, `vy ∈ [−7, 2]`; болтанка: общий предел 4, у ротора до 7.

**Что от чего зависит:** термики — от `θ′`/`w_conv` поля («между»), `маска` гасит фон; болтанка — от 8 каналов `turb_at`, скорости поля, `th.σ`, грозы/ротора/облака и среднего ветра **после** `_extra_flow`; аналитика — от `WindModel` (час и облачность меняют α и предел профиля), `GroundField`, `a`; гроза и облака — от термиков Cb и погоды; всё — от `time_s`, сида, фокуса (термики), `cloudbase_msl`, `sun_dir`.

**`decompose` (W7):** слагаемые `field, analytic, ridge, thermal, storm, wave, cloud, turb, gust` пишутся в `_rec` внутри той же функции (`:957–1195`); `Σ vel = total.xyz`, `total.w` — σ. Побитность `total` — следствие того, что запись не меняет счёта.

## RW-8. Болтанка поля и шум порывов

Подробно — `rw8-rw9.md`.
- **Исходники:** `field_turbulence.gd` 271, `gust_spectrum.gd` 172, шумовая часть `wind_model.gd` ≈ 75, турбулентный кусок суммы 1136–1213 + `_lee_burst_g`. ≈ 600 строк.
- **Входы:** `turbulence.*` (20 ключей), `lee.field_*` (14), `lee.burst_*`; 8 каналов `turb_at`, `a`, скорость поля, `sample_dx`; из других: `wd`, `_advect`, `relief`, `danger`, `th.σ` (10), σ гроз/роторов и `cin` (11), `conv_amp` (12).
- **Выходы:** `turb`, часть `gust`, σ (`total.w`); описаний нет. **Состояния во времени нет** (шум — чистая функция `(pos, t)`).
- **Случайность:** `FastNoiseLite` ×2 вида, RNG сдвигов и нормировки — порт (`godot-compat.md`).
- **Есть в Rust:** `turb_at`, `sample_turb`, `sample_dx` (`wind_field.rs:750`, `field_set.rs:237,269`); нет формул и шума.
- **Эталоны:** `ongudai_*` (6 случаев); сверять σ и MEAN; значения шума — порт или T3. **Тесты → cargo:** блок «с полем» `test_lee_rotor.gd`, часть `test_atmosphere.gd`, новые T3.
- **Объём:** ≈ 750 Rust + порт шума ≈ 330, 3–4 дня. **Риск:** форма `FastNoiseLite` Godot и порядок вызовов RNG — не проверены; σ до RW-10/11 не сойдётся в точках с термиками.

## RW-9. Аналитика и полоса края `a < 1`, режим `off`

Подробно — `rw8-rw9.md`.
- **Исходники:** профильная часть `wind_model.gd` ≈ 125, `ground_field.gd` 251, ветка аналитики суммы (`:921–1068`, `:1215–1267`, `:1075–1131`, `:1186–1213`), `mean_wind_at`, `background_wind`. ≈ 680 строк.
- **Входы:** `wind.*`, `ridge.*`, `lee.*`, `ground.*`; растры высот и воды, `start_sites[0].h_msl`; погода (`_derived.sun_elev_deg`, `sky`, `convective_turbulence_ms`, `background_sink_ms`).
- **Выходы:** `analytic`, `ridge`, часть `gust`; `background_wind`. **Состояние:** кеш `GroundField` по направлению ветра (сброс при повороте > 5°); профиль меняется по часу (зависит от RW-12).
- **Есть в Rust:** профиль (`wind_profile.rs:84–118`), доля поля, высота (`runtime.rs:499,1609`); нет `GroundField`, ridge/lee, `off`, `background_wind` (нули, `formula.rs:1186`).
- **Эталоны:** `synth_*` (аналитика целиком), `ongudai_*` (полоса края, `lee`); `off` не покрыт. **Тесты → cargo:** `test_atmosphere.gd`, `test_lee_rotor.gd` (блок 1), `test_wind_profile_simple.gd`.
- **Объём:** ≈ 850 Rust, 2–3 дня. **Риск:** высота — растр 25 м вместо `terrain.height_at` (линия тени, градиенты); отставание линии тени до 5° надо сохранить.

## RW-10. Термики и фоновое опускание, описания ядер

Подробно — `rw10-thermals.md`.
- **Исходники:** `thermal_field.gd` 1241, `air_thermals.gd` 1152, `atmo_thermal.gd` 151, ≈ 260 на стороне `Terrain` и фасада (сила источника, `cores`). ≈ 2 750 строк — **разбить** на 10c (сила источника), 10b (жизнь по клеткам), 10d (`AirThermals.build`), 10e (источники поля в жизни), 10f (замыкание с облаками).
- **Входы:** `thermal.*` (≈ 50), погода дня (≈ 17 ключей), поле (`raw_*`, мета), сила источника из растров, солнце, `cloudbase_msl`, фокусы, статичные термики, сид, `t`.
- **Выходы:** `thermal`, маска и σ края (в RW-8), **`cores` (W6)**, `thermals_near`; для RW-11 — список Cb. **Состояние:** чистая функция `(клетка, цикл)` + кеши; охват — по фокусам (круг 20 км, физика 6 км); пересборка источников поля при смене кромки, доли, солнца.
- **Случайность:** `RandomNumberGenerator` везде, порядок `randf` значим; `hash(Vector3i)` — точка источника.
- **Есть в Rust:** каналы поля для `AirThermals`, `mix_flux`, `SurfaceHeating`, солнце, `gauss2d`; нет жизни, `build`, силы источника, бакетов, `cores`.
- **Эталоны:** все 11 случаев (94–100 % точек); сетка клеток — `synth_*`, поле — `ongudai_*`; облачная часть — после RW-11. **Тесты → cargo:** `test_air_thermals{,_parallel,_relief}`, `test_subsidence`, `test_atmosphere` (термики), `test_clouds_and_generation`.
- **Объём:** ≈ 3 400 Rust, 12–14 дней в 4 подзадачах. **Риски:** петля с облаками; единичные расхождения числа ядер (дискретные решения); сила источника по растру 25 м вместо слоёв 10 м.

## RW-11. `_extra_flow`: гроза, волны и роторы, выброс из облака

Подробно — `rw11-clouds.md`.
- **Исходники:** `storm_field.gd` 118, `wave_field.gd` 198, `cloud_physics.gd` 517, `cloud_field.gd` 472, `cloud_field_sources.gd` 220, физика `cloud_model.gd` ≈ 160, кусок `atmosphere.gd` ≈ 170. ≈ 1 550 + `cloud_layer.gd` ≈ 300 строк правки.
- **Границу** см. выше (вывод 7): физика — крейт; выбор для рисования и слоты — Godot; К4-снимок сети не переносить.
- **Входы:** `storm.*`, `wave.*`, `clouds.*`, `cloud_field.*`, `thermal.suck_*`; погода (`wave_strength`, `stability_n_per_s`, `z_lcl`, `cloud_depth_m`, `cb_*`); термики Cb, `AirThermals`, поле. **Выходы:** `storm`, `wave`, `cloud`, `clouds()`, `cloud_raster()`, `wave_crests()`, `cloud_density_many`.
- **Состояние:** поле облаков — прогностическое (шаг 20 с, разгон 2 400 с при `start_at`), остальное — чистые функции. **Случайность:** `hash` башен; RNG у термиков.
- **Есть в Rust:** ничего (заглушки, `formula.rs:1177–1219`). **Эталоны:** `synth_storm`, `ongudai_day_2` (гроза), `synth_wave`, `ongudai_wave`; облака — слабо; нужны RW-2c.
- **Тесты → cargo:** `test_cloud_field*`, `test_cloud_suck`, `test_cloud_start`, `test_storm_rarity`, `test_hazards`, `test_wave`; рисование остаётся в GDScript.
- **Объём:** ≈ 2 000 Rust, 9–10 дней в трёх подзадачах + W6 v4 и `cloud_layer.gd` (2 дня). **Риски:** петля с RW-10; прошлое время у `CloudLayer`; одна гроза и одна волна в эталонах.

## RW-12. Погода из прогноза и ход дня, коэффициенты

Подробно — `rw12-weather.md`.
- **Исходники:** `weather_model.gd` 541, `atmo_day.gd` 113, коэффициенты и день в `atmosphere.gd` ≈ 270, `climate_grid.gd` 340 (данные). Новое для крейта ≈ 735 строк.
- **Входы:** условия-прогноз (W5), `weather_model.json`, `weather/*`, `atmosphere.json`, **`world.json`** (`time.*`), `loc.climate{,_lag}` + **полная ячейка климата** (нет в W5), растр высот.
- **Выходы:** словарь погоды (≈ 40 ключей + `_derived` ≈ 30), `AtmoDay` (`weather_at`, `bracket`), коэффициенты суммы, `sun_state`, условия профиля. **Состояние:** кеш шагов (512), мягкая смена (экспонента); значения берутся на сетке 0,1 с / 1 с. **RNG нет** (`td_noise` — splitmix64).
- **Есть в Rust:** `diurnal_state`, `sky_params`, `typical_max_c`, `ground_context`, `day()` (`z_i`, θ̄), `sun.rs`, `surface_heat.rs`; нет `derive`, `td_day`, `AtmoDay`, коэффициентов.
- **Эталоны:** три дневных случая, косвенно; словаря `derive` **нет** — нужен дамп. **Тесты → cargo:** `test_weather_model` (16), `test_weather_day` (5).
- **Объём:** ≈ 900 Rust, 3,5 дня. **Риски:** климат (блокер), дискретизация хода дня, зажим часов (6…21).

## Порядок

**Зависимости.**
- Каркас RW-8b и совместимость RW-8c — корни графа. Дальше: RW-8 ← 8b, 8c; RW-9 ← 8b (+ 8c для `gust`); RW-10c ← (поле, есть); RW-10b ← 8b, 8c, 10c; RW-10d ← 8c, 10c; RW-10e ← 10b, 10d, **12b** (дневные случаи); RW-11b ← 8b; RW-11c ← 10b; RW-11d ← 10b, 10e, 12b; RW-10f ← 11d; RW-11e ← 11c, 11d; RW-12b ← W5 v8; RW-12c ← 12b; RW-12z ← всё.
- RW-8 завершается полностью только после RW-10/11 (σ по `th.σ`, грозе, ротору); до того σ сверяется по формуле поля.

**Рекомендуемый порядок и параллельность (≤ 4 исполнителей).**
1. **А (2):** RW-8b ‖ RW-8c.
2. **Б (4):** RW-8 ‖ RW-9 ‖ RW-10c ‖ RW-12b (после W5 v8; пока его нет — на его месте RW-11b).
3. **В (4):** RW-10b ‖ RW-10d ‖ RW-11b ‖ RW-12c.
4. **Г (3):** RW-10e ‖ RW-11c ‖ (RW-11d стартует по готовности 10e).
5. **Д:** RW-10f, RW-11e, затем RW-12z (одиночно).

**Где сталкиваются правки.** `formula.rs` — только 8b и 12z; `terms/mod.rs` — по одной строке на задачу; `tools/wind_fixtures/gen_fixtures.gd` (54 КБ) — RW-2c и 12b, поэтому дамп погоды и новые случаи — отдельными файлами; общие конфиги — не меняются. Единое место общих типов (ветровая рамка: `dir`, `speed_at`, `advect`, `altitude_factor`, `vec2_at`) — RW-8b, иначе RW-8, 9, 10, 11 делают каждый свою.

**Что разбить:** RW-10 на 10b–10f (минимум), RW-11 на 11b–11e, RW-12 на 12b/12c; RW-8 — не нужно (≈ 600 строк), порт шума вынесен в 8c. **Что можно вести вперёд до контрактных правок:** 8b, 8c, 8, 9, 10c, 10b, 10d, 11b, 11c (на условиях «эталон»); блокируются W5 v8: 12b → 10e, 11d.

## Пробелы контракта

Предложения; менять контракты — только координатору.

1. **W5 (конфиги):** в `configure` нет `world.json` — из него идут `time.min_hour/max_hour/min_light_elevation_deg/utc_offset_h` (`AtmoDay`, `sun_direction`), `terrain_look.rock_slope_deg` и `surface.thermal.edge_*` (сила источника, правило скал). Предложение: имя `world` в списке W5; крейт читает только перечисленные ключи.
2. **W5 v8 (климат места):** `loc.climate` — 5 чисел; `derive`/`gain_per_km`/перистые требуют `td_c, td_sd_k, t700_c, z700_m, trop_m, wr → gain_per_km, hcc` и флаги `src.hh1/2/5/6`. Предложение: `loc.climate_full` (считает фасад по `ClimateGrid.place`), крейт файлы климата не читает; для воды — тот же набор на дату − `lag_days`.
3. **W5 (растры места для силы источника):** `water/cls/moist` 25 м не передают лесную/водную маски 10 м и поляны. Либо принять расхождение (`W8 v2`), либо добавить в `AirPlaceData` маски 10 м на область источников (вопрос RW-10c: сперва измерить долю столбцов, где сила отличается > 0,05).
4. **W6 v4 (Cb, гроза, волна для рисования):** запись Cb += `stage_growth/decay/activity, rx, rz, depth, spread, центр, ось сноса, life_fade, storm_start, storm_intensity, is_static, vis_seed`; `wave_enabled`. `clouds(center, radius)` с моментом `t ≤ now` (для окна истории `CloudLayer`; у `Live` — только текущий).
5. **W2/W4 (поверхностный порыв):** `GustDust` берёт `WindModel.gust_unit` прямо (`atmosphere.gd:2479`, TODO «этап 3»), порыв нужен **в прошлые слоты** `t0`. Предложение: `Atmosphere.surface_gust_many(xz, t) -> PackedFloat32Array` (м/с вдоль среднего ветра на 10 м = `max(u + σ·g·dir, 0)`, как `GustDustModel.gust_ms`), `t` — любой, для `Formula` — чистая функция; `Live` — текущий.
6. **W4 (`weather_json`):** договориться о составе — потребители читают `cirrus_cover`, `dust_devil_chance`, `lens_level_above_crest_m`, `haze_k`, `_derived.{valley_msl_m, sky, sun_elev_deg}`; остальное — по желанию.
7. **W4/W6 (охват фокусов):** в GD термики материализуются только в круге физики (6 км) вокруг фокуса (бакеты `_active`); вне его `sample_many` отдаёт поле, «между» и аналитику без пузырей. Зафиксировать в W4: «термики и облака считаются вокруг фокусов (`set_focuses`), дальше их нет» — иначе тест `far` (8 точек в случае) ждёт иного.
8. **W8 v2:** (а) число ядер — допуск «≤ 3 % и не более 2 на момент» с перечнем расхождений (дискретные решения); (б) точки `above_base` и 250 м под основанием — сверка только после RW-11; (в) режим `off` — случай RW-2c; (г) эталон погоды (дамп `derive`, `AtmoDay`) — файл рядом с `cases/`.
9. **W2/W3 (`field_export`):** переходная выдача поля удаляется с RW-12z (потребители — `ThermalField`, `FieldTurbulence`, `CloudFieldSources`); в W3 v5 это зафиксировать.

## Переход фасада

**Варианты.** (A) по слагаемому после каждой задачи: GD-сумма берёт готовое слагаемое из `DpAir`. (B) одним шагом после RW-8…12: `sample_many/decompose/cores/clouds/...` целиком в `DpAir`.

**Рекомендация — (B), RW-12z.** Доводы:
1. Слагаемые не аддитивны (вывод 1): болтанка зависит от среднего ветра со всеми добавками, σ — квадратами и ограничителями, в полосе края смешиваются; чтобы взять одно слагаемое из крейта, GD пришлось бы передавать ему остальные, то есть пересечь границу gdext на каждое слагаемое и точку — вопреки «одному вызову на пачку» (W3) и бюджету 50 мкс на 18 точек.
2. Сверка слагаемых и так идёт в `cargo test` против RW-2b (T1) — то, что дало бы промежуточное переключение, получено дешевле; решение пользователя 2026-10-27: T7/T9 и проверка пилотом — один раз после этапа 3.
3. Промежуточное переключение удвоит поддержку (две реализации в игре) и не освободит `scripts/` раньше RW-13.

**Что делает RW-12z (≈ 3 дня):** `Atmosphere.sample_many/sample/decompose/cores/clouds/cloud_raster/wave_crests/background_wind/weather/sun_state/cloud_density_many/cloudbase_msl` → `DpAir`; сигналы `weather_*` по `weather_version`; обёртки `air_velocity_at/mean_wind_at/turbulence_intensity_at/cloud_density_at` остаются (W2); `GustDust` и `world_link` — на фасад; `cloud_layer.gd` уже на W6 (11e). Затем удаляется `field_export` (dpair.md, v4) и его потребители; GD-слагаемые остаются до RW-13 как «эталон» (не в горячем пути).

**Что остаётся тестам.** Тесты `tests/` лезут во внутренности или старые обёртки (55 файлов обращаются к `.field/.wind/.ground/...`, `air_velocity_at`, `mean_wind_at`, `thermals_near`; из них 22 — к `air_velocity_at`): те, что перечислены в разборах, переписываются в `cargo`, остальные — на фасад (T7) или умирают в RW-13. Теневой режим «считать и там и там» не рекомендуется (двойная стоимость, расхождение допусков).

## Что не проверено (вопросы)

1. Форма `FastNoiseLite` Godot 4.7.2 и `randf` — дамп (RW-8c). 2. Доля столбцов, где сила источника по растру 25 м отличается от `Terrain` > 0,05 (RW-10c). 3. Стоимость пересборки `AirThermals` и поля облаков в Rust (нужен замер; GD ≈ 0,4–0,6 с и 120 шагов разгона). 4. Укладывается ли полная сумма в бюджет W8 (18 точек ≤ 50 мкс, 1000 точек ≤ 2 мс): поле сейчас 3,3 мкс на 18 точек (RW-6q); болтанка добавит до 30 вызовов шума на точку, термики — цикл по бакету с `pow/exp`; замера нет. 5. Нужен ли `off` вообще после RW-7 (поле считается всегда): план говорит «да» (режим «Эвристика» в настройках) — решение координатора.

## Источники и воспроизведение

Код: `scripts/atmosphere/{atmosphere,field_turbulence,gust_spectrum,wind_model,wind_profile,ground_field,thermal_field,atmo_thermal,storm_field,wave_field,cloud_physics,cloud_field,cloud_field_sources,cloud_model,weather_model,atmo_day,climate_grid,cloud_layer,gust_dust,gust_dust_model}.gd`, `scripts/atmosphere/air_model/{air_thermals,air_field_set,wind_field}.gd`, `scripts/terrain/terrain.gd:677–800,1056`; `rust/dp-air/src/{formula,field/*}.rs`; контракты `docs/contracts/rust-wind*.md`; конфиги `configs/atmosphere.json`, `weather_model.json`, `world.json`. Литература, на которую ссылается код (Ленчов 1980, Panofsky 1977, MIL-HDBK-1797, Bell & Mehta 1990, Allen 2006, Gedeon, Holtslag–Boville) — в docstring файлов; FastNoiseLite — MIT (Jordan Peck). Воспроизвести покрытие эталонами: numpy по `tests/fixtures/wind/cases/*.bin` (формат W8), см. `fixtures.md`; строки — `grep -n` по названным функциям.
