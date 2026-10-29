---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "Сводный список сомнений исполнителей RW-7 и этапа 3 для итоговой сверки перед RW-12z и сдачей модуля (решение пользователя 2026-10-29)."
conclusion: "Список ведёт координатор внедрения; каждая строка — что проверить в итоговом прогоне"
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3-path.md", "docs/plan/rust-wind.md"]
---

# Сомнения для итоговой сверки (RW-7, этап 3)

Ведёт координатор внедрения по полю `uncertain` отчётов (решение пользователя 2026-10-29: проверки по цене, тяжёлое — один раз в конце). Подробности — `.dpcli/dpcli report <ID> --show --full`.

| задача | где | сомнение | как проверить в конце |
|---|---|---|---|
| RW-7a | `rust/dp-air/src/formula.rs` `Shared::field_export` | мьютекс снимка держится во время zstd-кодирования; опросы поля из других потоков могут ждать | исправляет RW-8b (попутно); проверить в отчёте RW-8b |
| RW-7a | `rust/dp-air/src/formula.rs` `set_field_enabled` | отказ подготовки после включения → `Failed` (уточнено в W4 v5) | T7: тест фасада «включение поля в полёте» |
| RW-2c | `tests/fixtures/wind/cases/synth_off.*` | побитно равен `synth_medium`: синтетика и так идёт в режиме off — отдельного покрытия `off` на реальном рельефе нет | при RW-9 решить, нужен ли случай `off` на Онгудае |
| RW-2c | `tools/wind_fixtures/gen_fixtures.gd` `ongudai_storm` | ветер 14 км/ч с 151°, сид 909 — первый подобранный | достаточно точек `storm` (23) для RW-11c — посмотреть при постановке |
| RW-8c | `rust/dp-air/src/compat/rng.rs` | правило `randf` (два слова, `ldexp`) и `randf_range` подобраны по дампу Godot 4.7.2 | при смене версии Godot — `tools/wind_fixtures/compat_dump.sh --verify` |
| RW-8c | `rust/dp-air/src/compat/noise.rs` | портированы только NONE и FBM, без `rotation_type_3d`, ping-pong, 2D | новые вызовы шума в слагаемых — сверять с дампом |
| RW-12b | `rust/dp-air/src/field/weather_core.rs` `sun_elevation_deg`, `weather/tables.rs` `seg` | эмуляция f32 (`Vector2` в GD) ради совпадения ~1e-7; функция общая с полем | полный T1 поля (`acceptance_release`) в итоговом прогоне; для сведения на RW-12b — 12/12 PASS (job `rw12b-acc`, 2026-10-29) |
| RW-12b | `rust/dp-air/src/field/weather_core.rs` | `WeatherModelCfg` += `raw`, `altitude_gain_per_km` (из `atmosphere.json`) | то же |
| RW-12b | `rust/dp-air/src/weather/climate.rs` `PlaceCtx` | += `utc_offset_h`, `start_msl_m` (NaN — не задано); `gain_per_km` зависит от высоты старта | RW-12c/RW-10e: откуда берётся `start_msl_m` в игре — сверить с `_f_weather_ctx` |
| RW-7b | `scripts/atmosphere/atmosphere.gd` | поле считается только для условий-прогноза, пресет — без поля (как с AirRuntime); строже W2 «Режим поля» | T7: превью и тесты с пресетом — нужно ли поле |
| RW-7b | `scripts/atmosphere/air_place_data.gd` | `utc_offset_h = NaN` → `center_lon/15` | места без часового пояса — сверить час поля |
| RW-7b | `scripts/atmosphere/atmosphere.gd` | при пилотских слоях конфигов — слитый JSON (числа float), при одном слое — файл как есть; со слоями не проверено | T7 с пилотским слоем |
| RW-7b | растр «карта фаз» (W7 `debug_raster`) | пуст: крейт карту фаз не отдаёт | RW-12z/RW-13: решить, нужен ли оверлей |
| RW-7b | `docs/guide/game/cli-tests.md`, `docs/guide/air-model/debug.md` | описан удалённый `--air-field` | RW-13 (документация) |
| RW-8b | `rust/dp-air/src/terms/sum.rs` | порядок и ограничители суммы — по чтению GD, слоты пустые: проверяется только при наполнении слотов | итоговый T1 итога FULL/MEAN |
| RW-8b | `rust/dp-air/src/terms/frame.rs` | высота солнца в рамке — 52° (до RW-12c), `AirCase.Z0`, `F_COR` — константы | RW-12c подключение; T1 `analytic` дневных случаев |
| RW-8b | `rust/dp-air/tests/terms_frame.rs` | эталон `synth_medium` содержит тень гребня; сверка рамки — только в свободном воздухе | RW-9 (линия тени) |
| RW-8b | `rust/dp-air/tests/runtime.rs` | в accept упал без вывода теста под нагрузкой (вероятно, сигнал/таймаут), повтор 35/35 PASS | итоговый прогон: следить за runtime под нагрузкой |
| RW-12c | `rust/dp-air/tests/runtime.rs:983` `ongudai_size_cancel_in_every_stage_returns_within_a_second` | тайминговый порог 1 с, под нагрузкой 1,016 с (флейк) | итоговый прогон отдельно; при повторе — поднять порог или гонять с --test-threads=1 |
| RW-12c | `rust/dp-air/src/weather/` | эталон W8 v2 `cases/<имя>.weather.json` не делался (дамп функций) | при подключении погоды к сумме (RW-12z) — дневные случаи |
| RW-10b | `rust/dp-air/src/terms/mod.rs` `Terms::advance` | построение набора термиков синхронно в `advance_to`: 2 мс при бюджете 0,5 мс (W3) | RW-10e/RW-12z: вынести в фон или инкрементально; бенч в итоговом прогоне |
| RW-10b | `terms/thermal/mod.rs` `ThermalSlot::empty` | слот инертен без земли — до RW-10e термиков и фонового опускания нет; после подключения — снять хеш clipmap заново | RW-10e |
| RW-10b | `terms/thermal/mod.rs` `PlaceGround::is_water` | вода — ближайший узел растра 25 м, GD — класс слоя 10 м | RW-10e: сверка на Онгудае/островах |
| RW-10b | `rust/dp-air/tests/terms_thermal.rs` | синтетика в GD идёт с упрощённым профилем (air_model off); число пропущенных точек (вне растра, above_base) не в отчёте | итоговый T1 |
| RW-10c | `terms/thermal_src/mod.rs` `edge_proximity`, `Grid::bilinear(moist)` | классы кромок из cls 25 м, влажность — растр 25 м вместо поля 50 м; доля |Δ| > 0,05 против terrain-пути — 1,57 % (Онгудай 0,4–7,1 % по часам) | принято как граница W5; сверка ядер в RW-10e |
| RW-10c | `SourceHour::at` / `atmo_sun` | часовой множитель не сверен с `AtmoDay.source_fn` на потоке часов | RW-10e (с RW-12d) |
| общее | `rust/dp-air/tests/runtime.rs` `picard_cancel_during_the_setup_returns_within_the_limit`, `ongudai_size_cancel_…` | тайминговые пороги падают под нагрузкой accept (275–522 мс, 1,016 с) | RW-0g: вынести в итоговый прогон |
| RW-10d | `rust/dp-air/tests/data/RW-10d/ongudai_medium/field.bin` | эталон поля — f16 (запечённое, w_mech обнулён), не f32 без потерь (бюджет 5 МБ); strong/wave — только счётчики, тестом не читаются | итоговый прогон: источники strong/wave по дампу из опорной ревизии |
| RW-10d | `terms/thermal_air/pick.rs:20-60` | водная ветка `pick_in_column`/`land_fraction` не сверена с GD на реальных данных | RW-10e: острова |
| RW-10d | `terms/thermal_air/mod.rs` `BuildIn::u10` | `u10` параметром (GD — `level.meta.u10`) | RW-10e |
| RW-11b | `terms/waves/` на `ongudai_wave` | волна смотрит на 3λ ≈ 43 км против ветра, растр места ±20 км: за краем — высота края; с эталоном по terrain.height_at расходится до 5,5 м/с (120/189 точек) | вопрос к итоговой проверке: дальний грубый рельеф для волн (W5) |
| RW-11b | `terms/waves/mod.rs:50` `WaveExtra::flow` | Mutex на каждый вызов flow и на кусках поля (ревью, minor) | RW-12z: бенч W8 с волной |
| RW-11b, RW-9 | `WaveExtra::field`, `analytic/ground.rs:PlaceSig::of` | кеш места по указателю и длине растра — новое место по освобождённому адресу не сбросит кеш | RW-12z: ключ места — версия `set_place` |
| RW-11b | `tests/terms_waves.rs:terms_of` | упрощённый профиль synth_wave включён тестом вручную; Formula при air_mode off должна включать сама | RW-12z |
| RW-12d | `terms/weather_link.rs` `PlaceLink::of`, `ref_msl` | start_msl_m и ref_msl = NaN (GD ставит h_msl старта для ref_msl); t0 хода дня = 0 как в GD `_f_build` | RW-12z: сверка фасада с Godot в итоговом прогоне |
| RW-12d | `weather_link.rs` `advance_weather` | true на каждом слоте 0,1 с хода дня — фасад будет пересобирать часто | RW-12z: порог изменения |
| RW-9 | `tests/terms_analytic.rs:248` после слияния с RW-11b | synth_wave: σ аналитики больше эталона на 0,079 (90/93) — волна попадает в σ аналитики? | RW-9 доработка (note) |
| RW-10e | `terms/thermal/air.rs` `PickAdapter` / растр места W5 | на растровой силе 4,8 % ядер (81/1692) с другим местом: класс узла 25 м против маски 10 м у границ классов; на силе из журнала GD — в допуске W8 | итоговая проверка: маска 10 м в растре места (W5) или принять |
| RW-10e | `tests/data/RW-10e` | 4,96 МиБ — у края бюджета 5 МБ; журнал силы strong/wave в f32 (GD — f64) | RW-12z/итог: не расти |
| RW-10e | `terms/thermal/mod.rs` `advance_bg` | фоновая пересборка под нагрузкой не проверялась | итоговый прогон T1 |
| RW-11d | `terms/clouds/mod.rs` `AnalyticInputs` | кромка и ground_ref аналитического пути — из Setup слота термиков, у GD env.cb/cloudbase_ref; на местах с полем не сверено | итоговый прогон |
| RW-11d | `terms/clouds/mod.rs` `CloudSlot::advanced` | start_at(t) = reset на входах момента t (как GD), от прогона с 0 отличается (cover max 0,07) | W2 «как после прогона с 0» — в смысле детерминизма; итог |
| RW-11d | `terms/clouds/field.rs` `set_inputs` | шаг поля 0,43 мс при бюджете advance_to 0,5 мс + клон 0,5 МБ на шаг; разгон 56 мс и prepare 4 мс синхронно при смене ключа | RW-12z: бенч W3, фон |
| RW-11d | `terms/clouds` chaos_noise | бурление в облаке — нули (gust_unit ветровой рамки нет до RW-9) | после RW-9 |
| RW-11d | `terms/mod.rs` `Terms.clouds` | слот облаков в Terms, не в Slots | RW-12z |
| RW-11d | `tests/terms_clouds.rs:828`, `:1078` | assert «установилось» почти пуст (`|| q_full > 0.0`); слагаемое cloud против W8 — 9 ненулевых из 516 точек | RW-10f: сверка above_base шире |
| RW-10f | `terms/thermal/mod.rs` `rebuild`, `Terms::advance` `synced_with_clouds` | порядок шага (порождение — облака до шага, подсос — после) выведен из GD refresh_now; T6 start_at ≠ прогон с 0 при облаках (и в GD) | RW-12z: W2 v4 формулировка start_at |
| RW-10f | `terms/thermal/mod.rs` `cloud_changed` | смена только cloud_size_factor без шага поля подхватится при следующей version | итоговый прогон |
| RW-10f | `tests/terms_thermal_cloud.rs` `AirInputs` | входы поля облаков собраны в тесте (аналог CloudFieldSources.prepare с air); в игре — RW-12z | RW-12z: подключить CloudInputs из Field+AirThermals в Terms |
| RW-8 | `terms/turb/mod.rs` `FieldTurb::z0` | z0 уровня подобран по lee (в дампе GD нет), совпадение с Field::z0() Rust без Пикара не проверено | итоговый прогон T1 |
| RW-8 | `terms/turb/mod.rs` `sigma advect`, `ground_ref` | крейт считает wind.speed_at(300) на каждом опросе (GD кеширует в set_wind); cloudbase для конвективной σ — из погоды, в GD — ThermalField/GroundField | RW-12z |
| RW-8 | `terms/turb/mod.rs` `state` | mean()/sigma() повторно считают sample_turb/lee; бюджет 18 точек ≤ 50 мкс не замерен | RW-12z: бенч W8 |
| RW-8 | точки отрыва (lee_f>0, 352/1244), ex2 термика/грозы | в тесте relief и ex2 из дампа GD | после RW-9: сверка живого слота |
| RW-9 | `terms/analytic/strip.rs` | разрыв GD на краю a→0+ (ротор без множителя нагрева в полосе) перенесён буквально, скачок ~16 % | после модуля: исправление отдельно |
| RW-9 | `tests/terms_analytic.rs` `load_with` | пресет W5 не несёт ref_msl ветра прогноза — тест берёт из эталона; без него ветер вдвое | RW-12z: ref_msl в пресете/фасаде (связано с RW-12d) |
| RW-8s | `terms/surface_gust` | «нет места / не READY — нули» (W6) — не в функции, у Terms нет признака места; свой GustUnit по configs+seed (не из слота Turb) | RW-12z: обнуление в фасаде; общий GustUnit |
| RW-8s | `tests/data/RW-8s/` | эталон Онгудая — WindModel+GustDustModel с ручными сидами/ветром, не полный прогон Atmosphere на месте | итоговый прогон |
| RW-12u | `tests/terms_thermal_field.rs:68-85` `load` | гонка: параллельные тесты одного процесса копируют одни файлы в общий tmp `rw10e_cases_<pid>` — EOF/обрезанный .bin (2 из 3 прогонов accept) | RW-0g: уникальный tmp на вызов |
| RW-12u | `lib.rs` `ObjRecord` | FLAG_STATIC/FLAG_CB/FOREVER остались в terms::objects | RW-12v |
| RW-12w | `rust/dp-gd/src/bridge.rs` `obj_f32s` | unsafe-каст `&[ObjRecord]` → `&[f32]` (repr(C) + const-assert размера и выравнивания); ObjRecord не реализует F32Record | RW-12v: `impl F32Record for ObjRecord` в dp-air, каст убрать |
| RW-12w | `tests/contracts/test_dp_air_ext.gd` | api_version 4 и три метода на пустом объекте — Godot не запускался | итоговый прогон T7 |
| RW-9 | `terms/waves` σ ротора на synth_wave | GD кладёт rotor_turb в σ аналитики (atmosphere.gd:1038) — стык верный, но число WaveExtra расходится с GD в 4/93 точках (p7 0,03↔0,73; p9 2,33↔0,74; p16 0,95↔0,85; p36 0,93↔0); тест RW-9 — доля ≥ 95 % | RW-11g: исправить ротор, тест — по точкам W8 |
