---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-26"
summary: "RW-6a, таблицы: шаги пути поля Пикара (файл:функция, ключи конфига) и карточки задач RW-6b…6q"
conclusion: "Приложение к docs/research/rust-wind-field-path.md: полные таблицы шагов и задач"
data: "tools/research/rust_wind/window_estimate.json"
applied_in: ""
related: ["docs/research/rust-wind-field-path.md"]
---

# RW-6a: таблицы шагов и задач

Приложение к `docs/research/rust-wind-field-path.md` (там выводы и рекомендации). Номера строк — на момент разбора, ветка `feature/rust-wind`.

## Путь поля по шагам (загрузка места → опрос точки)

Сквозное: `Game._load_air_field` → `AirRuntime.setup/load_field` → `_begin` → `_prep_task` → фазы → грубый Пикар → Пикар → сборка `WindField` → окна → `_levels_done` (проход 2) → `_apply` → `Atmosphere.set_air_field` → `AirFieldSet.sample`. Значения конфига — `configs/atmosphere.json`, блок `air_model` (и `air_phase`), если не сказано иное. Все пути — в `scripts/atmosphere/air_model/` (дальше «am/»).

| № | Шаг | Файл:функция | Вход → выход | Где считается | Ключи конфига, значение сейчас |
|---|---|---|---|---|---|
| 1 | Место | `am/air_runtime.gd:place_of` (270) | `Terrain` → `{detail: HeightLayer 25 м, water: Image, surface: AirPlace.Surface, loc, start_sites}` | главный поток; снимок поверхности — задача пула (`AirPlace.surface_start`) | — |
| 2 | Условия | `air_runtime.gd:conditions_of` (339) | часы, `air.weather`, `FlightSettings` → `{hour, u10, wdir, t_max, sky, wind_ref}` | главный поток | `u10 = wind_speed_kmh/3.6` (меню), `t_max = settings.temperature_c`, `sky = settings.sky` |
| 3 | Запечённое поле / кеш | `air_runtime.gd:load_field` (378), `_load_baked` (493), `_load_cached` (633) | условия → поле из файла вместо расчёта (шаги 4–14 пропускаются) | рабочий поток + главный | `baked_enabled = true`, `air_cache.max_mb` (см. «Пересчёт, запечённые поля и кеш») |
| 4 | Запуск | `air_runtime.gd:_begin` (935), `_start_prep` (971) | условия → число проходов (1 или 2), `k` притока, точка старта `_start_pt = focus_fn()` | главный поток | `max_passes = 2` (код), `pass_tol = 0.03`, `INFLOW_K_MIN/MAX = 0.3/1.0` (const) |
| 5 | Подготовка входа | `air_runtime.gd:_prep_task` (1011), `_domain` (1048) → `am/air_place.gd:domain_case` (33) | место + условия + `k` + шаг `dx` → `AirCase` (сетка 96×96×nz, `hc`, `gam`, `z_i`, `z_i_col`, `z0_map`, `heat`, `u10`, `alpha`, `max_profile`) | рабочий поток (`WorkerThreadPool`), области 1200 м и 400 м **параллельно** (`PoolFor`); ~0,5 с на 400 м | `DX = 400` (const), `DOMAIN_L = 38400`, `picard_coarse_factor = 3` |
| 6 | Плоскости случая | `PreparedCase.from_case` (`air_runtime.gd:1758`) → `am/air_case.gd:prepare` (289) | `AirCase` → `col` (14 плоскостей), `lev` (5), `prm`; то же без нагрева (`without_heat`) | тот же рабочий поток (2 потока пула); ~0,7 с пара на 400 м | `p.*` в `air_case.gd` (не в конфиге) |
| 7 | Фазы | `am/air_phase_job.gd` + `air_phase.glsl` (GPU) или `am/air_phase_cpu.gd` (CPU, float64); `am/air_phase.gd:prepare` | `PreparedCase` → `weights (7·ny·nx)`, `omega`, `freeze`, `freeze_mech`, `warm`, `mech_field`, `mech_field_mech`, `stats` | GPU порциями по 8 мс (`air_phase.chunk_ms`); без порций — CPU в рабочем потоке (`_prep_task`) | весь блок `air_phase.*`; `omega.use_map = false`; `nonconv.mech_w = 0.5`, `nonconv.late_from = 500`, `omega.fallback_iters = 300`, `omega.fallback_omega = 0.5` |
| 8 | Грубый Пикар | `air_runtime.gd:_after_phases` (1116), `_poll_coarse` (1139), `coarse_start` (1177) | грубый случай 1200 м (32×32) → `warm_coarse = {dims, x0, y0, dx, z_bot, mech: state, heat: state}`; пропускается, если есть прошлое поле этой сетки или `all_mech(фазы)` | GPU, `mech = true` (пара mech→heat), порции `LOAD_CHUNK_MS = 30`; при ошибке — старт с фона | `picard_start = "coarse"`, `picard_coarse_factor = 3` |
| 9 | Пикар 400 м | `air_runtime.gd:_start_picard` (1267), `am/air_picard_job.gd` | `PreparedCase` + `warm`/`warm_heat`/`warm_coarse` + `freeze_*`, `omega_map` (если `use_map`), `late_from`, `nonconv_*`, `omega_fallback` → два решения (mech, потом heat) | GPU порциями (`poll_slice(40 мс)` при загрузке, `FLIGHT_CHUNK_MS = 5` в полёте) | `tol_mom/th/div = 2e-5/5e-7/1e-6` (`air_picard_job.gd:79`), `check_every = 10`, `max_outer = 3000`, `timeout_s = 60` |
| 10 | Перенос грубого на мелкую сетку | `air_picard_job.gd:_prolong` (389) → ядро `air_picard.glsl:K_PROLONG` | грубые `u,v,w,th,thd,p` → 400 м: билинейно по горизонтали в индексах грубой сетки со смещением начала, по высоте тот же `dz`, сдвиг уровней `ksh = (z_bot − z_bot_грубой)/dz` | GPU | — |
| 11 | Сборка `WindField` | `air_picard_job.gd:field_async` (1188), `_build_field` (1215) → `am/wind_field.gd:from_mac` (170) | состояния `u,v,w(heat),w(mech),th,tcode,hc` с ореолом → поле без ореола в центрах граней; `w_conv = w − w_mech`; клэмп | чтение буферов — главный поток, сборка — рабочий (~0,2–1 с) | `max_speed_ms = 40`, `max_w_ms = 10` |
| 12 | Окна | `air_runtime.gd:_start_windows` (1388) → `am/air_clipmap.gd`, `air_window_case.gd`, `air_window_job.gd`, `air_window.glsl` | поле области как родитель → окно 100 м (64×64) → окно 50 м; граница от родителя (nest), поправка потока Σ=0 | GPU порциями; подготовка входа — рабочий поток | `window_levels_m = [100, 50]`, `window_shift_frac = 0.25` |
| 13 | Проход 2 | `air_runtime.gd:_levels_done` (1472), `start_speed` (1579), `_next_k` (1557), `inflow_p` (1529) | уровни → U на 10 м над стартом → `k₁ = k₀·(u10/U)^(1/p)`, p по таблице `INFLOW_P` = [[3; 0,57], [6; 0,75], [10; 0,90]], `k ∈ [0,3; 1]`; проход 2 стартует от состояния прохода 1 (`warm_second_pass`, окна — на тех же местах) | главный поток | `max_passes = 2`, `pass_tol = 0.03`; «inflow» или штиль (`u10 < WindProfile.U10_MIN`) — один проход, `k = 1` |
| 14 | Подача | `air_runtime.gd:_apply` (1600) → `Atmosphere.set_air_field` (`scripts/atmosphere/atmosphere.gd:533`) → `am/air_field_set.gd:set_field` | уровни (мелкий → грубый) + `blend_s` (загрузка — 0, пересчёт — по умолчанию `_air_blend_s`) | главный поток | `blend_s = 60`, `edge_blend_cells = 5` |
| 15 | Опрос | `atmosphere.gd:air_velocity_at` (763) → `AirFieldSet.sample` → `WindField.sample` | точка (мир) + `ground_h` → скорость и доля поля 0..1; остаток (1 − доля) заполняет аналитика | главный поток, горячий путь | — |
| 16 | Пересчёт | `air_runtime.gd:_process` (878, стадия IDLE), `needs_recompute` (825), `slot` | условия изменились → `_begin(c, причина, loading = false)`; час округляется вниз до срока (`slot_hour`) | как загрузка, но один проход, `k = inflow_k` последней загрузки, тёплый старт обоих решений | `recompute_game_min = 15`, `WIND_TOL_MS = 0.05`, `DIR_TOL_DEG = 1`, `TMAX_TOL_C = 0.25` (const) |
| 17 | Сдвиг окон | `air_runtime.gd:_update_windows` (1437) → `AirClipmap.update` | пилот ушёл от центра окна дальше 0,25 стороны → окно и все мельче пересчитываются | GPU фоном, только в покое (`Stage.IDLE`) | `window_shift_frac = 0.25` |

Замечание о потоках. Решение сейчас целиком опрашивается из `_process` главного потока порциями (GPU). В крейте оно станет **одной фоновой задачей** (свой `rayon::ThreadPool`, `INTEGRATION.md`, «Нити и вызов в фоне») — этапы PREP/PHASE/COARSE/SOLVE/BUILD/WINDOWS перестают быть конечным автоматом главного потока; `Stage` остаётся только как `Status.progress` и причина (`W4: Status`).


## Задачи RW-6b…RW-6q

Каждая ≤ 1 дня агента (RW-6c, RW-6g, RW-6i — верхняя граница, при перегрузе делить). Скоуп — каталог крейта `rust/dp-air/src/field/…`, `rust/picard_rs` где указано. Зависимости: RW-4 (workspace, `dp-air`, W4), RW-5 (стенд `dp-stand compare`).

| ID | Цель | Скоуп файлов | Зависит от | Тесты |
|---|---|---|---|---|
| RW-6b | Вход области: `block_mean` 25 → 400 м, сетка и `nz`, `gam`, `z_i` (поиск по θ̄), `AirZiTerrain`, `cell_surface`/`cell_z0`/доли воды из растров W5 | `dp-air/src/field/place_input.rs` | RW-4 | T1-вход: `hc`, `gam`, `z_i`, `z_i_col`, `z0_map` против дампа GD (образец `tools/research/air_cascade/warm/dump_inputs.gd`): `hc` ≤ 1e-3 м, `gam` ≤ 1e-7 К/м |
| RW-6c | Погода и солнце для поля (`weather_core`): `diurnal_state`, `sky_params`, `typical_max_c`, `diurnal_range_k`, `ground_context`, `SunClock.solar_position`, `SurfaceHeating`, `SurfaceHeat`, `surface_flux`, `WindProfile` | `dp-air/src/field/weather_core.rs`, `…/surface_heat.rs` | RW-4 (параллельно RW-6b) | поток тепла `H[ny·nx]` и `d`-сводка против GD ≤ 1 Вт/м²; α, `max_profile`, класс устойчивости — точно |
| RW-6d | Плоскости случая: `AirCase.prepare` (`kf`, неизвестные, фон, `closure`, `col/lev/prm`), без нагрева | `dp-air/src/field/case_prepare.rs` | RW-6b, RW-6c | `col/lev/prm` против дампа GD (нужен небольшой GD-дампер плоскостей — в скоуп `tools/research/rust_wind/`); T2 свойства (непротекание) |
| RW-6e | `K_SETUP` и остальное, что даёт игровой GPU до первой итерации → R1-массивы в памяти (`picard_rs::Case`), проверка «Case в памяти» | `dp-air/src/field/case_build.rs`, правка `rust/picard_rs/src/case.rs` (конструктор из памяти) | RW-6d | собранный случай против R1 Онгудая из `$AIR_CASCADE_DATA` (`ongudai_d400_*`, f64, скаляр `z_i`) и против случая из дампа игры; затем решение: итерации в допуске AP-20 |
| RW-6f | Грубый старт: общая операция «грубый → мелкий» (`prolong`), цепочка 1200 → 400 м, оба состояния; ошибка грубого → старт с фона | `dp-air/src/level.rs`, `dp-air/src/field/coarse.rs` | RW-6e (полная цепочка), тест `prolong` — без зависимостей | **T4a** (см. ниже) |
| RW-6g | Заморозка колонн в решателе: маска, поле, `K_FREEZE`, `K_RMASK`, `K_FIXROW`, счёт неизвестных, `all_frozen`; отмена `solve` | `rust/picard_rs/src/{solver,lines,kernels}.rs` | RW-6e | T4: невязка и дивергенция по незамороженным; побитное совпадение при пустой маске с прежним (регрессия R6 v3); отмена за ≤ 1 итерацию. Контракт `picard-rs` R6 → v4 (меняет координатор) |
| RW-6h | Запасные правила: ω-откат после 300 итераций, `late_mean` с 500-й, подмена колонн `nonconv`; `max_outer = 3000` | `rust/picard_rs/src/solver.rs` | RW-6g | синтетический случай, не сходящийся: поле := среднее, `nonconv_fallback = true`; штиль 12:00 из `limits.md` (161 итерация) |
| RW-6i | `Field` в Rust: `from_mac`, `sample*`, приземный слой, `edge_weight`, столбцы u*, w*, hmix, `FieldSet` с подменой `blend_s` | `dp-air/src/field/{wind_field,field_set}.rs` | RW-4 (параллельно RW-6b…6h) | T1-поле против запечённых полей (`data/locations/*/air/*`, f16, три уровня) через `dp-stand compare`; T2: непрерывность на краю, `blend_s` монотонно, пределы |
| RW-6j | Оркестровка: конвейер загрузки (вход → грубый → пара → `Field`), два прохода `k`, `needs_recompute`/`slot`, тёплые состояния, фон в своём пуле, таймаут, откат на прошлый проход, `Status.progress`, политика потоков | `dp-air/src/field/runtime.rs`, подключение к `Formula::{load_place,set_conditions,advance_to,start_at}` | RW-6e, RW-6f, RW-6i | T2 (подмена, срок), T8 (смена места во время расчёта, выход, 2/4/20 потоков), k-проходы на синтетике против `AirRuntime._next_k` |
| RW-6k | Фазы 1: `AirPhase.prepare`, классификатор, веса, маски заморозки, ω | `dp-air/src/field/phase/{prepare,classifier}.rs` | RW-6b | числа `test_air_phase.gd` (Σweights, оси U10 0,3/1,5/12) |
| RW-6l | Фазы 2: механизмы A (DCT), B, D (SOR), H | `dp-air/src/field/phase/{linear,bubble,layers}.rs` | RW-6k | числа CPU-тестов P10 (`phases.md`, таблица) и сверка с `AirPhaseCpu` на синтетике 24×24 |
| RW-6m | Фазы 3: F, G (Прандтль, D8), сборка `warm`/`mech_field`/`mech_field_mech`/`nonconv_field`, статистика | `dp-air/src/field/phase/{convection,drainage,assembly}.rs` | RW-6k | σ_w/w*, `a_up`, w* (Allen), Прандтль `l`, `Δθ`; затем **T1 слабого ветра** по фикстурам RW-1 |
| RW-6n | Окна 1: `AirWindowCase`, вложенная граница (`nest`), `flux/corr`, `shift`, ядро `nest` как `level::nest` | `dp-air/src/field/window.rs`, правки `picard_rs` (граница от родителя) | RW-6g, RW-6e | сверка с `window_gpu_refs.py` (Онгудай w100/w50, итерации 40/40/50, поправка потока 1,7e-3 м/с) |
| RW-6o | Окна 2: клипмап (очередь, сдвиг за фокусом, подмена набора), интеграция в `runtime` | `dp-air/src/field/clipmap.rs` | RW-6n, RW-6j | T2: нет разрыва на краю окна; период сдвига; откат при ошибке окна |
| RW-6p | Запечённые поля и кеш диска: чтение формата TI-К3 v3 (f16, zstd), ключи, решение о перепечке | `dp-air/src/field/baked.rs` | RW-6i | запечённое поле острова читается и совпадает с GD-выборкой (T1) |
| RW-6q | Приёмка RW-6: `Formula` отдаёт слагаемое «поле» + разложение W7, T1/T4/T4a/T2 зелёные, бенч-базовая линия `baseline.json` | `dp-air`, `tests/fixtures/wind/` | всё выше | T1 по W8, T4, T4a, T2, `cargo bench` ≤ порогов W8 |

**Порядок и параллельность.**
- Поток A (вход): RW-6b ‖ RW-6c → RW-6d → RW-6e.
- Поток B (решатель): RW-6f (тест `prolong`) ‖ RW-6g → RW-6h. Не зависят от потока A до RW-6e.
- Поток C (поле): RW-6i, не зависит ни от кого, кроме RW-4; RW-6p за ним.
- Поток D (фазы): RW-6k → RW-6l ‖ RW-6m; не зависят от решателя (RW-6k берёт `AirCase` из RW-6b), нужны в RW-6g/6h как вход масок.
- Поток E (окна): RW-6n → RW-6o, последний хвост.
- Склейка: RW-6j (после A, B-часть f, C), затем RW-6q.
- Первый видимый результат (поле Пикара в Rust на сильном ветре без фаз и окон): RW-6b, 6c, 6d, 6e, 6f, 6i, 6j — около 7 агент-дней, при трёх параллельных потоках ~3 календарных. Полный RW-6 с фазами и окнами — около 13–15 агент-дней; оценка в `rust-air-integration.md` (6–11 дней всего на встраивание) относится к меньшему объёму.

