---
type: "research"
status: "active"
module: "wind-forecast"
area: "air"
updated: "2026-11-08"
summary: "Аудит привязки ветра к старту: места файл:строка, U над стартом start/inflow на 8 стартах, загрузка, кеш, wind_ref."
conclusion: "Подгонка k реально срезает ветер над наветренным стартом (U над стартом ×1,16–1,29 при inflow), загрузка без второго прохода в 2,1–2,7 раза короче там, где проход 2 идёт. Запечённых полей в игре нет, перепечка не нужна; старые записи кеша с k ≠ 1 просто не совпадут с новым ключом. wind_ref прогноза на поле не влияет, только на аналитический фон (шлюз)."
data: "tools/research/wind_forecast/"
applied_in: ""
related: ["docs/plan/wind-forecast.md", "docs/contracts/wind-forecast.md", "tools/research/lee_cal/README.md"]
---
# WF-1: аудит привязки ветра к старту

Ветер меню (`u10`) в поле — амплитуда притока на краю области. Привязка к старту: (а) подгонка `k` под U над стартом (режим `inflow_mode = start`, по умолчанию),
(б) `wind_ref.ref_msl` прогноза = высота старта (аналитический фон), (в) тексты «ветер на старте». Замеры — только Rust (`dp-air` `Formula`, без Godot), см. «Воспроизведение».

## Места
Правка «удалить» = убрать целиком; все пути относительно корня.

### Rust (`rust/dp-air/src`)
| файл:строка | что | правка |
|---|---|---|
| `field/runtime.rs:88-92` `INFLOW_K_MIN/MAX`, `INFLOW_P` | пределы k 0,3…1 и показатель закона U ∝ k^p | удалить |
| `field/runtime.rs:94-104` `START_AGL_M`, `U10_MIN`, `MAX_PASSES`, `PASS_TOL` | высота замера U, порог, число проходов | `MAX_PASSES`, `PASS_TOL` удалить; `START_AGL_M` оставить, если нужен «на старте X» (U10_MIN нужен профилю, `wind_profile.rs:7`) |
| `field/runtime.rs:180-181,300-301` `cfg.max_passes`, `cfg.pass_tol` | поля конфига оркестровки | удалить |
| `field/runtime.rs:340-363` `CondRec.inflow`, `:401` `needs_recompute` (`have.inflow != want.inflow`) | режим в условиях поля и в причине пересчёта | удалить поле и проверку |
| `field/runtime.rs:424-466` `inflow_p`, `PassLog`, `next_k` | подбор k | удалить |
| `field/runtime.rs:587` | `"inflow"` в ключе кеша (`cache_key`) | удалить ключ (см. «Запечённые поля и кеш») |
| `field/runtime.rs:700-710` `JobIn.k_mem`, `inflow_k` | память k по румбу, k для пересчёта в полёте | удалить |
| `field/runtime.rs:1617-1632` выбор `passes`/`k` в `run_job`; `:1645-1700` цикл проходов, `hit_iter_limit`, `next_k` | до 2 проходов, `warm` из прохода 1 | цикл → один `solve_pass(k = 1.0)`; `warm`/`prev_ok`/`pass_failed` проходов убрать, `JobReport.planned`, `.log`, `.pass_failed`, `.not_converged` — убрать или оставить пустыми |
| `field/runtime.rs:1671` `start_speed_levels` (+`:1491-1560` `start_speed`) | U над стартом для подбора | подбор убрать; функция пригодится для «На старте X м/с» (U10 над стартом из готового поля) |
| `field/runtime.rs:1735-1754` | `inflow_k` в `meta`/`extra` записи кеша и `SolvedField` | удалить |
| `field/runtime.rs:1-30,49` (doc-комментарий) | описание «Проходы k» | переписать |
| `field/case_prepare.rs:133,143-155,215` `AirCaseRs.inflow_k`, `CaseOpts{k, inflow_mode}`, `effective_k` | k и режим в случае | `CaseOpts` без k и режима; `AirCaseRs.inflow_k` удалить (u10 = u10_menu) |
| `field/clipmap.rs:410` | `inflow_mode: job.rec.inflow` в `CaseOpts` окон | удалить поле; `:1575` `k: b.inflow_k` в `runtime.rs` — удалить |
| `field/solved.rs:39-40,112-124` `SolvedField.inflow_k` (`meta.inflow_k`) | k в формате записи кеша/поля | удалить поле; читателя `meta.inflow_k` убрать |
| `formula.rs:262,271` | `inflow_k` в экспорте поля (`FieldExport`/`ExpMeta::of(pl, k)` `:1018`) | убрать k из экспорта |
| `formula.rs:555-556,655-656,753-754` | `inflow_k`, `k_mem` в `Formula`, геттер `inflow_k()` | удалить |
| `formula.rs:914,937,974-978,1046-1047,1125` | перенос k и режима между задачами; сравнение `c.inflow == cond.inflow_mode` | удалить |
| `formula.rs:1325-1326,1368-1369` | сброс `inflow_k`, `k_mem` | удалить |
| `conditions.rs:36-51,67,90-93,141` `InflowMode`, ключ `inflow_mode` | разбор и хранение режима (в `Conditions` и в `Source`-видах) | удалить enum и ключ; `lib.rs:27` экспорт `InflowMode` убрать. Ключ в старом JSON → ошибка «посторонний ключ» (совместимость не нужна) |
| `conditions.rs:17-29,62,111-126` `WindRef` | `wind_ref` прогноза | **не трогать до шлюза** (ниже) |
| `terms/weather_link.rs:36,179-203` | `wind.ref_msl = w.ref_msl`, `gain_per_km` из климата на высоте `ref_msl` | по решению шлюза |
| `formula.rs:815-826` `default_ref_msl` | без `wind_ref` ref_msl = h_msl первого старта места | ещё одна привязка к старту, по решению шлюза |
| `terms/frame.rs:136,262-270` `altitude_factor` | рост ветра от `ref_msl` | по решению шлюза |

### Godot / GD (`scripts`)
| файл:строка | что | правка |
|---|---|---|
| `scripts/game/game.gd:596` | `"wind_ref": {"ref_msl": _start_pos.y}` | по решению шлюза |
| `scripts/game/game.gd:597` | `"inflow_mode": StartWeather.wind_ref_of(settings)` | удалить ключ |
| `scripts/game/game.gd:587-589` (doc) | «ветер у старта» | переписать |
| `scripts/game/start_weather.gd:9-10,49-56,88-90` | `WIND_REFS`, разбор `weather.wind_ref`, `wind_ref_of()` | удалить; в `parse` ключ `weather.wind_ref` теперь недопустим/игнорируется (решить: игнор с предупреждением) |
| `scripts/atmosphere/atmosphere.gd:99,1168-1169` | `inflow_mode` в `COND_KEYS_COMMON` и в проверке | удалить |
| `scripts/game/calm_air.gd:86` | `"inflow_mode"` в списке допустимых ключей | удалить |
| `scripts/atmosphere/air_model/air_baked_field.gd:460-486` `conditions_of`/`conditions_diff`, поле `wind_ref` | условия запечённого поля | см. «Запечённые поля и кеш» |
| `scripts/atmosphere/air_model/air_case.gd:109-114,214,241,252-254` `inflow_k`, `u10_menu`, `set_inflow` | k в GD-случае (наследие GPU-пути) | проверить использование (после rust-wind воздух считает крейт); если не используется — удалить |
| `scripts/atmosphere/air_model/wind_field.gd`, `scripts/atmosphere/wind_model.gd:162-165` `altitude_factor` («множитель от высоты над стартом») | наследие GD, `WindModel` запрещён тестом чистоты (`tests/contracts/test_rust_wind_purity.gd:22`) | не живое; убрать вместе со своим комментарием при чистке |
| `scenes/main.gd:512-543` `_maybe_show_start_hint`, `scripts/ui/controls_screen.gd:60-72`, `locale/ui.csv:511-512` | подсказка при запуске полёта (куда добавить «на старте X м/с») | задача «На старте X м/с»; `Game._wind_at_launch` в `scripts/game/achievement_feed.gd:137` уже считает U на 10 м над стартом из поля (образец) |
| `tools/flight/wind_penetration_run.gd:4,140,158`, `tools/bench/air_velocity_bench_main.gd:120` | инструменты с `"inflow_mode": "start"` | удалить ключ |

### Данные и конфиги
| файл:строка | что | правка |
|---|---|---|
| `configs/locations/training_island.json:62,80,98,116`, `configs/locations/volcano_island.json:74,92,110,128` | `weather.wind_ref` (`start`/`inflow`) у 8 стартов | удалить ключ; `lee_bowl` и `crater_ridge` (были `inflow`) остаются как есть — поле то же |
| `tools/terrain/island/weather_sets.json` (4 набора), `tools/terrain/volcano/make_config.py:34-44` `SLOPE_WX` | источники этого ключа | удалить ключ |
| `configs/atmosphere.json:165,224` | комментарии «ветер прогноза на старте, с поправкой на высоту» | уточнить по решению шлюза |
| `configs/atmosphere.json:808` `wind_reference_agl_m` | высота ветра для длины волны (1500 м AGL) | не относится (не старт) |
| `tests/fixtures/wind/cases/*.json` (`conditions.inflow_mode` в `ongudai_day_1/2` — start, `ongudai_day_3` — inflow; `wind_ref` во всех дневных) | фикстуры W8 | ключ `inflow_mode` убрать из JSON и из `tests/contracts/test_wind_fixtures_format.gd:155,197-204` (проверка «есть inflow и start» → удалить); `ongudai_day_1/2` — эталонный выход считался с k < 1, переснять или убрать из W8 с причиной |
| `tests/fixtures/wind/README.md:45-52` | таблица фикстур с `inflow_mode` | обновить |

### Тесты
| файл:строка | проверяет | действие |
|---|---|---|
| `rust/dp-air/tests/runtime.rs:544-615` `gd_next_k`, `k_pass_follows_next_k_formula_and_stops_by_pass_tol` | формула next_k, остановка по pass_tol | **удалить** (нет подбора) |
| `rust/dp-air/tests/runtime.rs:619-660` `inflow_mode_is_a_single_pass_with_k_one` | один проход с k=1 | **переписать**: один проход всегда |
| `rust/dp-air/tests/runtime.rs:675-710` `next_k_inflow_p_and_recompute_rules` | next_k, inflow_p, правила пересчёта | next_k/inflow_p **удалить**, правила пересчёта (`:716` `inflow: Start`) оставить без поля `inflow` |
| `rust/dp-air/tests/runtime.rs:195-196,1555-1573`, `acceptance.rs:209-210,897-900` | `k_mem: None, inflow_k: 1.0` в `JobIn`; `m.inflow_k()` «k переносится» | убрать поля; сравнение `inflow_k` — удалить |
| `rust/dp-air/tests/case_prepare.rs:353,471-514` `inflow_mode_forces_k_one` | режим → k=1 | удалить |
| `rust/dp-air/tests/contract.rs:690-702` `conditions_inflow_mode`; `:44,599-610` | разбор `inflow_mode` (+неверные значения) | заменить проверкой «`inflow_mode` — посторонний ключ»; `wind_ref` пока как есть |
| `rust/dp-air/tests/clipmap.rs:799`, `window.rs:176` (`inflow_mode: Start`), `clipmap.rs:82`, `zz_dynamic_thermals.rs:94`, `step_cost_same.rs:80`, `formula_facade.rs:65`, `game_thermals.rs:76`, `acceptance.rs:834` (`"inflow_mode":"inflow"` в JSON) | условия случаев | убрать ключ; поведение то же (`inflow` = уже k=1) |
| `rust/dp-air/tests/{runtime,acceptance,clipmap,w11v9_w5v7}.rs` `report.passes[0]`, `.passes.last()` | это `PassReport` каждого прохода решения (фазы, итерации), не k | оставить, проход теперь один (`passes.len() == 1`) |
| `tests/contracts/test_rust_wind_contracts.gd:403-415`, `test_rust_wind_consumers.gd:24-25`, `test_feedback_1013_contracts.gd:103`, `tests/atmosphere/{test_air_status_iters_gpu,test_debug_layers,test_ridge_starts,test_rw7_field_from_crate}.gd`, `tests/game/test_place_air_stage.gd:119` | GD-тесты условий с `"inflow_mode"` | убрать ключ (и проверку «inflow_mode вне списка — BAD_INPUT» в `test_rust_wind_contracts.gd:403`) |
| `tests/contracts/test_training_island_k3.gd:47,132,214-220` | `inflow_k` в формате записи, `wind_ref` в `conditions_of/diff` | по решению об `air_baked_field.gd` |
| `tests/game/test_forecast_game.gd:49`, `tests/atmosphere/test_weather_day.gd:18-28`, `rust/dp-air/tests/{terms_frame,terms_analytic,weather_ported}.rs` | `wind_ref` {ref_msl, gain_per_km} | по решению шлюза |

### Тексты и документы (в задачу «Документы»)
| файл:строка | что | правка |
|---|---|---|
| `docs/guide/air-model/runtime.md:61-62,87-105` | «Поле под старт», два прохода, `INFLOW_P`, `AirRuntime` | заменить: один проход, `k = 1`; GD `AirRuntime` — устарел (поле считает крейт) |
| `docs/guide/air-model/runtime.md:143-155` «Запечённое поле старта и `wind_ref`» | запечённых полей нет (RW-P12) | удалить раздел |
| `docs/guide/air-model.md:58` | `air_runtime.gd` «два прохода» | удалить строку |
| `docs/guide/air-model/surface-heat.md:53` | U над стартом при k = 1 | уточнить |
| `docs/guide/location-data.md:166-176,180-191` | `wind_ref` start/inflow в наборах; «запечённое поле», TI-9 | убрать колонку `wind_ref`, абзацы про запечённые поля |
| `docs/guide/volcano-island.md:39,42` | «k притока 0,98», `wind_ref` | обновить |
| `docs/guide/fast-load.md:27-33` | ключ кеша включает `wind_ref`, порядок «запечённое → кеш» | исправить: ключ без режима; порядок «кеш → расчёт» |
| `docs/guide/atmosphere/weather.md:13`, `docs/guide/game/menus-settings.md:20` | «ветер на старте» (меню) | «ветер прогноза (10 м над открытой местностью)» |
| `docs/contracts/training-island.md:64-68,87`, `docs/contracts/fast-load.md:31`, `docs/contracts/rust-wind/input.md:34`, `docs/contracts/rust-wind.md:95`, `docs/contracts/air-model/{input-solver,runtime-calibration,field-consumers,divergences-journal}.md` | контракты TI-К2 v2, FL-К1, W5 v2, C9 | версии контрактов (делает координатор) |
| `CHANGELOG.md:53,110,522,599` | прошлые записи (история) | не менять; новая запись «В работе» |
| `REQUIREMENTS.md:80,126`, `questions.md:101`, `configs/game.json:11,13` (`default_wind_speed_kmh_doc`), `locale/ui.csv:15` (`setup_wind` «Ветер по прогнозу») | «ветер на старте» | `game.json` doc-строки и `REQUIREMENTS.md` FR-16 — «ветер прогноза»; `ui.csv:15` остаётся |
| `site/content/mechanics/weather.ru.md:107`, `site/content/approaches.{ru,en}.md:105-111`, `site/content/docs/training`, `launch-camp` | текст сайта про ветер над стартом/калибровку | поправить по итогам; `approaches` — история |
| крылья `site/content/wings/**` «Ветер на старте/Wind at launch» | предел ветра класса крыла, не привязка поля | не относится |

## U над стартом
Rust, `dp-air::Formula`, `mean` на 10 м над землёй старта. 6 м/с, 12 ч, пасмурность/ясно как в наборах мест; острова — наборы `weather_sets.json` (ветер 1–8,5 м/с).
Режим `start` — текущее поведение; `inflow` — будущее (один проход, k = 1). Максимум по сетке ±2,4 км, шаг 100 м, на 100 м AGL.

| место | меню м/с | U10 start | k | проходов | U10 inflow | inflow/start | max100 start | max100 inflow |
|---|---|---|---|---|---|---|---|---|
| ridge_west (наветренный) | 6.0 | 5.69 | 0.756 | 2 | 7.36 | 1.29 | 10.32 | 13.42 |
| thermal_plain | 2.0 | 1.23 | 1.0 | 1 | 1.23 | 1.00 | 2.80 | 2.80 |
| landing_hill | 1.0 | 0.91 | 1.0 | 1 | 0.91 | 1.00 | 1.73 | 1.73 |
| lee_bowl (в тени) | 8.5 | 1.19 | 1.0 | 1 | 1.19 | 1.00 | 18.36 | 18.36 |
| ongudai (151°, kayancha_south) | 6.0 | 6.16 | 0.707 | 2 | 7.68 | 1.25 | 9.48 | 12.06 |
| ongudai_back (331°) | 6.0 | 5.95 | 0.816 | 2 | 6.87 | 1.16 | 10.28 | 12.17 |
| volc_east_cliffs | 6.0 | 5.92 | 0.980 | 2 | 6.00 | 1.01 | 9.35 | 9.53 |
| volc_crater_ridge | 6.0 | 4.62 | 1.0 | 1 | 4.62 | 1.00 | 10.12 | 10.12 |

Выводы:
- Там, где k < 1 (наветренные: ridge_west, ongudai ×2, east_cliffs), поле при inflow сильнее над стартом на 1–29 % и на 100 м по карте на 2–30 %: подгонка срезает настоящий разгон. Прогноз 6 м/с над ridge_west даёт 7,4 м/с на старте (×1,23 меню), над Онгудаем 7,7 (×1,28).
- Где k = 1 (4 из 8: thermal_plain, landing_hill, lee_bowl, crater_ridge) поле при start и inflow одно и то же (U и max совпадают до округления; побитно не сверялось) — для них удаление подгонки ничего не меняет. Старты в тени (lee_bowl: 1,19 м/с при меню 8,5; crater_ridge: 4,6 при 6) и так «слабее меню».
- Слабый ветер (thermal_plain 2 м/с, landing_hill 1 м/с): проход 1 дал U < меню, k упёрся в 1 (предел), проход 2 не запускался (`planned = 2`, `passes_run = 1`).
- Не равно меню и в режиме start: k подбирается до допуска (проход 2 даёт 5,72 против 6,0 у ridge_west в журнале крейта; моя выборка 5,69).
- Границы: окна 100/50 м входят в поле; U взято из `sample_many(Mean)` в точке x,z старта по билинейной земле fixture (не по сетке 25 м игры); `Formula` без `attach_weather` (климат запасной) — на поле не влияет (ветер = `forecast.wind_speed_kmh/3.6`). Askarovo (biyagoda_west/east) стенду не подать: места нет в `tests/fixtures/wind/places/` (там ongudai, training_island, volcano_island, synthetic) — вместо этого второй румб Онгудая и два старта вулканического острова. Для Askarovo нужен fixture места (сборка из игры) — не делал, правка кода и обходы через Godot запрещены карточкой.

## Загрузка
Rust, до `Ready` с `start_at(0)` и фокусом на старте; кеш выключен (нет `set_cache_dir`). **Замок CPU режет процесс до 1 ядра (cgroup CPUQuota=100%)**, поэтому абсолют (1 ядро, детерминированный режим) выше, чем у игрока; отношение сохраняется. Одно измерение на пару, повторов нет (разброс не оценён; пары thermal_plain/landing_hill/lee_bowl/crater_ridge дают 0,97–1,01 — оценка шума ≈ ±3 %).

| место | start, с | inflow, с | отношение |
|---|---|---|---|
| ridge_west | 210.0 | 77.0 | 2.73 |
| ongudai | 209.8 | 83.0 | 2.53 |
| ongudai_back | 178.6 | 84.3 | 2.12 |
| volc_east_cliffs | 59.7 | 43.7 | 1.37 |
| thermal_plain | 25.4 | 25.6 | 0.99 |
| landing_hill | 22.3 | 22.0 | 1.01 |
| lee_bowl | 86.3 | 86.9 | 0.99 |
| volc_crater_ridge | 45.5 | 46.9 | 0.97 |

Без второго прохода загрузка там, где он шёл (k ≠ 1), короче в 1,4–2,7 раза: проход 2 (прогоны `mech`+`heat` области и окон с тёплого старта) стоит больше прохода 1 (`runs` 5 против 3). Где k = 1, выигрыша нет (проход 2 и так не запускался).

## Запечённые поля и кеш
- Запечённых полей в игре нет: `data/locations/*/air/` удалены в rust-wind (RW-P12, `docs/research/rust-wind-stage3/no-baked.md`), шлюз «перепечка» снят. Остались: тестовая фикстура `tests/fixtures/wind/baked/training_island/landing_hill.{json,bin}` (key.weather.wind_ref = `start`, `meta.inflow_k = 0.3` на всех трёх уровнях — **нигде не загружается**, только `tools/research/rust_wind_t1_ref/run.sh` её печатает; можно удалить), `rust/dp-air/tests/data/RW-10d|e/*/field.json` (`inflow_k = 1.0`, `key` пуст; используются тестами термиков `terms_thermal_field.rs` как есть) и `data/wind_field/field.json` (другой формат, k нет).
- Кеш полей крейта (`field/field_cache.rs`, `user://air_cache/*.dpac`, формат `cache: 2`): ключ собирается в `field/runtime.rs:560-590` (`kind, format 1, location, center, month, day, utc, place, configs, domain_dx, step_min, start, hour, u10, wdir, t_max, sky, inflow`); в заголовке записи `inflow_k` в `extra` и `meta` (`runtime.rs:1735-1738`, `SolvedField.inflow_k`). **Правка:** убрать `"inflow"` из ключа, `inflow_k` — из `extra`/`meta`/`SolvedField`. После этого старые ключи (с `"inflow"`) не совпадут по хешу имени и по `key_diff` → промах, файлы стареют по LRU (`max_mb`, по умолчанию 200 МБ) — **перепечь не нужна, чистить вручную не обязательно**. Поднимать `CACHE_FORMAT` (`field_cache.rs:24`) в принципе не нужно, но дёшево и гарантирует удаление записей с k ≠ 1 (читатель отвергает и удаляет чужой формат).
- На машине пользователя (`~/.local/share/Deltaplan/air_cache`, 11 записей): `inflow = start` везде; `inflow_k` = 1,0 у 9, 0,636 (volcano_island, thermal_slope 3 м/с) и 0,528 (training_island, 1 м/с) у 2 — записи со срезанным ветром. Скрипт: `cache_scan.py`.
- Остатки GD: `scripts/atmosphere/air_model/air_baked_field.gd` (21 КБ: `save`, `load_file`, `make_key`, `conditions_of/diff`, `model_hash`, `code_hash`). Живой вызов один — `AirBakedField.model_hash()` в `scripts/atmosphere/air_place_data.gd:240` (`fill_crate_inputs`: `header.model_hash`, ключ кеша). Остальное — только тест `tests/contracts/test_training_island_k3.gd`. **Правка:** перенести `model_hash`/`code_hash` (+`code_hash_of_sources`) в маленький файл (например `scripts/atmosphere/air_model_hash.gd`) и вызывать оттуда; `air_baked_field.gd` и `test_training_island_k3.gd` — удалить (формат записи теперь у крейта, `field/baked.rs`/`solved.rs`). Следить: файлы `scripts/atmosphere/air_model/` входят в хеш кода (`docs/guide/fast-load.md:27`), поэтому правка там сама меняет `model_hash`, а значит делает все существующие записи кеша промахом — **перепечка/чистка кеша произойдёт сама**.

## Шлюзы
1. **`wind_ref {ref_msl, gain_per_km}` прогноза — это «ветер на высоте старта», а не «10 м над открытой местностью», но на поле Пикара он не влияет.** `game.gd:596` кладёт `ref_msl = _start_pos.y` (отметка старта над морем); `terms/weather_link.rs:184-203` пишет её в `WindModel.ref_msl`, `gain_per_km` — из климата на высоте `ref_msl` (`PlaceCtx.start_msl_m`); `terms/frame.rs:262-270` даёт `speed_at_pos(agl, msl) = speed_ref · profile(agl) · (1 + gain·(msl − ref_msl)/1000)`, т.е. скорость прогноза = скорость на отметке старта, выше старта сильнее, ниже слабее. `formula.rs:815-826` при отсутствии `wind_ref` подставляет отметку первого старта места (ещё одна привязка). Поле Пикара берёт `u10 = wind_speed_kmh/3.6` (`field/weather_core.rs:235`) и от `ref_msl` не зависит (проверено кодом: в `field/` нет `ref_msl`/`gain`). `ref_msl` влияет только на аналитический ветер: фон вне окон (`background_wind`, `terms/mod.rs:435-450`), `terms/sum.rs:66` (`Ctx.u`), `analytic/mod.rs:198,289,421`, `turb/mod.rs:113` (`lee_danger`) — то есть на опасность подветренной зоны, болтанку и фон вне области. Сейчас этот ветер согласован с полем только на отметке старта.
   Варианты (выбирает пользователь до правки):
   - **A. Оставить как есть** (ref_msl = старт). Поле = «ветер прогноза над открытой местностью», аналитика/болтанка = «ветер прогноза на отметке старта»: расхождение на горных стартах (Онгудай +1,0…+1,2 км над долиной при gain 0,6–0,73/км — аналитика даёт +60…90 % к прогнозу против поля). Правок нет, непоследовательно с решением пользователя.
   - **B. `ref_msl` = опорная высота открытой местности** (долина/средняя отметка места: `PlaceCtx.valley_msl_m`/`mean_msl_m`, они уже есть в `place_context`). Аналитика соответствует прогнозу «над открытой местностью», рост ветра считается от долины; на старте выше долины аналитика даст больше прогноза (как ветер в горах и должен быть). Правка: `game.gd:596`, `weather_link.rs`, `formula.rs:815`; последствие — на горных стартах аналитический фон на отметке старта выше, чем сейчас на `gain·(h_start − h_valley)`, изменятся пороги опасности подветренной зоны и болтанка вне поля; тесты `terms_frame`, `weather_ported`, `test_forecast_game.gd:49` (ожидание «на высоте старта ветер по румбу») — переписать.
   - **C. Убрать `wind_ref` совсем** (`ref_msl = NaN`, `altitude_factor = 1`): ветер не растёт с высотой в аналитике; поле не меняется. Минимум правок и полная согласованность «10 м над открытой местностью», но пропадает рост ветра с высотой (CHANGELOG:53,599 — «5 м/с на старте, на километр выше около 14 м/с», заявленная особенность), а `default_ref_msl` надо убрать вместе. Нужно решение пользователя: терять ли рост с высотой.
   Рекомендация: **B** (рост от отметки открытой местности сохраняется, смысл прогноза выдержан), если не хочется терять рост с высотой; иначе C. Решение пользователя до задач «Убрать подгонку» (она не зависит от шлюза и может идти раньше).
2. **Перепечка запечённых полей — не нужна** (запечённых полей нет; старые записи кеша сами станут промахами).

## Список правок
**Убрать подгонку (engineer).** Удалить всё из таблиц «Места» → Rust/GD/данные/тесты (кроме строк «по решению шлюза»); один проход, `k = 1`; `JobReport` без `log`/`planned`/`pass_failed` проходов; ключ кеша без `"inflow"`, без `inflow_k`; `CACHE_FORMAT` → 3 (по желанию); `air_baked_field.gd` → вынести `model_hash`/`code_hash`, остальное и `test_training_island_k3.gd` удалить; из `configs/locations/*.json` и источников (`weather_sets.json`, `make_config.py`) убрать `weather.wind_ref`, а `StartWeather` — разбор; из фикстур W8 убрать `inflow_mode`, `ongudai_day_1/2` переснять; тесты — по таблице «Тесты» (удалить `k_pass_follows_next_k…`, `next_k_inflow_p…`, `inflow_mode_forces_k_one`, `conditions_inflow_mode` → «посторонний ключ»). Приёмка: поле при k = 1 совпадает с прежним `inflow` (см. «U над стартом»: 4 места k = 1 — одно и то же, 4 места k < 1 — поле меняется, ожидаемо); время загрузки — 1,4–2,7 раза короче на мест k < 1.
**«На старте X м/с» (engineer).** Место — `scenes/main.gd:512-543` (`_start_hint`, текст `controls_screen.gd:60-72`, ключи `start_hint_*` в `locale/ui.csv:511-512`); U — как в `achievement_feed.gd:137-150` (`air.mean_wind_at(Vector3(x, ground+10, z))`, `sample` Mean, длина (x,z), направление «откуда»); поля ещё нет (`field_on` false, аналитика) — не показывать строку или «ветер у старта считается». Ожидаемые числа (6 м/с меню): над ridge_west 7,4; над Онгудаем 7,7 (151°) / 6,9 (331°); в тени (lee_bowl) 1,2 при меню 8,5 — подсказка должна быть понятна, что меню — прогноз, а у старта — результат.
**Документы (writer).** Таблица «Тексты и документы» выше; плюс удалить устаревший раздел «Запечённое поле старта и `wind_ref`» из `docs/guide/air-model/runtime.md` и описание GD `AirRuntime`; CHANGELOG «В работе»: «Ветер меню — как в прогнозе (10 м над открытой местностью), а не над стартом: на наветренных склонах у старта ветер сильнее прогноза, в тени слабее; в начале полёта показывается ветер у старта; загрузка без второго прохода быстрее».

## Воспроизведение
    .dpcli/dpcli job --lock cpu start wf1-scan 3600 tools/research/wind_forecast/run.sh before   # ≈ 32 мин на 1 ядре
    .dpcli/dpcli job wait wf1-scan 3600
    python3 -I tools/research/wind_forecast/summary.py        # summary.json + таблицы (tables.md)
    python3 -I tools/research/wind_forecast/cache_scan.py ~/.local/share/Deltaplan/air_cache   # ключи и k записей кеша
Код: `rs/` (Cargo-проект вне workspace `rust/`, зависит от `dp-air` и `dp-stand` путём), `run.sh`, `summary.py`, `cache_scan.py`. Выходы: `out/` (в .gitignore), `rows_before.json` (сырые строки), `summary.json`, `tables.md`.
Источники: коды и фикстуры репозитория (место/условия — `tests/fixtures/wind/places/*.json`, наборы — `configs/locations/*.json`); внешних данных и лицензий нет.
Допущения: детерминированный режим `Formula`, один запуск на пару (разброс времени ≈ ±3 % по парам с k = 1), температура/небо/час — из наборов мест, Онгудай — `ongudai_day_1` (24 °C, ясно, 12 ч), gain_per_km = 0,6 (на поле не влияет).

## WF-2: сверка после удаления подгонки

Подбор `k` удалён, поле всегда при `k = 1` (один проход). `rs/` теперь считает один режим (новый код); `run.sh after` → `out/after.json`, малая копия — `after.json`; `compare_after.py` сверяет с прежним `inflow` из `summary.json` (U10 у старта и max на 100 м, 8 мест): **`max_rel = 0`** — побитно то же поле (округление как в `summary.json`: U10 до 3 знаков, max100 до 2). Загрузка (1 ядро, Rust, `ready_s`), с: прежний `start` → теперь — ridge_west 210 → 86,5; ongudai 210 → 95; ongudai_back 179 → 93; volc_east_cliffs 60 → 46; остальные четыре без изменения (там и прежде был один проход). `summary.py` читает `out/before.json` (два режима) и к новому `rs/` не подходит — это прежний срез.
