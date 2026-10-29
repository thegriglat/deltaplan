---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "Итог этапа 3: T1 release 13/17, workspace 4 падающих бинарника, tests_vs_base +108, бенч W8 в порогах, T9 нет"
---

# Итоговый прогон этапа 3 (RW-12r)

Прогон ветки `feature/rust-wind` (`ff43a5912`) после перехода фасада (RW-12v). Код не менялся. Логи — в `build/` копии (`build/tests_vs_base/`, `build/xc/`); логи задач — `~/.cache/dpcli/deltaplan/jobs/rw12r-*.log`.

## Шаги

| # | Команда | Время | Итог |
|---|---|---|---|
| 1 | `tools/build_rust.sh tune linux` | 3 мин 02 с | ok, `addons/dp_air/bin/libdp_air_tune.so` (243 МБ) |
| 2 | `godot --headless --path . --import` (профиль копии) | — | exit 0 |
| 3 | `cargo test --workspace -- --include-ignored` (первый прогон, без `--no-fail-fast`) | 1455 с (acceptance) | остановился на первом падающем бинарнике (acceptance) |
| 3b | `cargo test --no-fail-fast --workspace -- --include-ignored` | 1376 с (acceptance), 892 с (runtime), 14 с (terms) | 4 бинарника с падениями, остальные ok (см. ниже) |
| 4 | `cargo test --release -p dp-air --test acceptance -- --ignored` (T1) | 1616 с | 13 passed, 4 failed (ожидание: test result ok ≥ 12 — не выполнено) |
| 5 | `cargo bench -p dp-air` (W8) | — | числа ниже, все в пределах порогов |
| 6 | `tools/tests_vs_base.sh --base main` (lock cpu tvb) | 1-й прогон: таймаут файла задачи 7200 с, на подтверждении обрезан; 2-й прогон (кеш базы): 4131 с | новые падения: 108 (см. ниже) |
| 7 | T9 `tests/atmosphere/xc/xc_run.tscn` | — | не выполнен (см. ниже) |

## Падения cargo workspace (no-fail-fast)

Формат: `файл::тест` — сообщение (повтор: нет, см. «Не сделано»).

- `dp-air/tests/acceptance.rs::t1_open_training_island_landing_hill` — `training_island/landing_hill: k расходится на 0.09312303421137558` (дебаг, 2 прогона); в release — то же падение.
- `dp-air/tests/acceptance.rs::t1_open_training_island_thermal_plain` — `training_island/thermal_plain dx50: вне допуска` (дебаг, release).
- `dp-air/tests/acceptance.rs::t1_open_volcano_island_thermal_slope` — `volcano_island/thermal_slope dx50: вне допуска` (дебаг, release).
- `dp-air/tests/acceptance.rs::t1_training_island_thermal_plain_windows` — `training_island/thermal_plain dx50: вне допуска` (дебаг, release).
- `dp-air/tests/runtime.rs::ongudai_advance_to_latency_release` — `advance_to at delivery took 1.714636ms (W3: <= 0.5 ms)`.
- `dp-air/tests/t1_stability.rs::stab_compare` — `RW6Z_DIFFS: NotPresent` (паника в t1_stability.rs:402).
- `dp-air/tests/t1_stability.rs::stab_run` — паника в t1_stability.rs:349 (текст в логе не расшифрован, см. «Не сделано»).
- `dp-air/tests/terms_thermal_field.rs::w8_strict_place_and_points` — `ядер не сошлось по месту: 81 из 1692`; сводка: ongudai_medium — точек вне допуска 9, место не сошлось 42; ongudai_strong — вне допуска 2, место не сошлось 19.

Остальные крейты (dp-air unit, baked, case_build, case_prepare, clipmap, contract, field_export, field_input, fixtures, formula_facade, …, doc-tests dp_gd/dp_stand/picard_rs) — ok.

Повтор падений по одному отдельно (правило «один повтор при нагрузке») не выполнен: прогон занял лимит времени на T9/tests_vs_base. Все падения — из прогонов под замком cpu, но без явного повтора.

## Бенч W8 (cargo bench -p dp-air)

| Бенч | Время (low / median / high) | Порог | Итог |
|---|---|---|---|
| sample_many_18 | 8.51 / 8.89 / 9.34 нс | ≤ 50 мкс | ok |
| sample_many_1000 | 170.9 / 171.1 / 171.4 нс | ≤ 2 мс | ok |
| advance_to | 3.50 / 3.51 / 3.52 нс | ≤ 0,5 мс | ok |
| formula_sample_many_18 | 51.6 / 52.2 / 52.8 мкс | — (справочно) | — |

Примечание: `advance_to` 3.5 нс в бенче при 1.71 мс в тесте `ongudai_advance_to_latency_release` — разные условия (микробенч без полного места/данных). Число для W3 — из теста.

## GDScript против main (tools/tests_vs_base.sh --base main)

Base main: `831fe3d3c7`. Копия: 521 файл. Базовые падения: 43. Падения копии: 145.

- Новые падения копии (108) — полный список в логе задачи `rw12r-tvb2`. Примеры: `tests/contracts/test_rust_wind_contracts.gd::test_signals`, `…::test_start_at_vs_run_from_zero`, `tests/contracts/test_wind_fixtures_format.gd::test_day_cases_set`, `tests/contracts/test_wing_physics_contracts.gd::test_k3_menu_wind_is_u10`, `tests/game/test_forecast_game.gd::test_game_uses_forecast`, `tests/ui/test_wind_model_setting.gd::test_setting_saved_and_applied`.
- Исправлено относительно main (6): `tests/atmosphere/test_air_place.gd::test_cell_fractions_synthetic`, `…::test_domain_input_vs_reference`, `…::test_surface_determinism_ongudai`, `tests/atmosphere/test_storm_rarity.gd::TIMEOUT`, `tests/contracts/test_air_contracts.gd::test_c2_surface_input`, `tests/game/test_game_flight.gd::test_air_start`.
- Стена второго прогона 4131 с; первый прогон — таймаут задачи 7200 с во время подтверждения.

## T9 — боты xc

- `xc_run.tscn` на ongudai (`--location=ongudai --weather=medium --seed=1 --wind=15,270 --km=30`): не выполнен. Скрипт вернул `{"error": "location"}`: в профиле копии нет `user://locations/ongudai/meta.json` (место собирается при первом выборе в игре); задача `rw12r-xc` завершилась по таймауту 1800 с (код 124), Godot не вышел после ошибки.
- `--synthetic --seed=1 --km=30` (без места): запуск остановлен вручную после ~20 мин; в логе 2 `SCRIPT ERROR: Invalid assignment on read-only value (on base: 'Dictionary')`, `out_synthetic.json` не записан. Результата нет.
- Сравнения с main для T9 не делалось.

## Не сделано

- Повторные прогоны падений по одному (правило «один повтор при нагрузке»).
- T9: нет ни одного успешного прогона; нужна сборка места в профиле копии или исправление скрипта xc_run.gd — решение координатора.
- Расшифровка паники `stab_run` (t1_stability.rs:349) — не разобрана.
- Числа T9 и повторы — отдельным прогоном после решения.

## uncertain

- Причина 108 новых GDScript-падений не разобрана (код не менялся, но копия собрана под tune). Возможна нагрузка/таймауты, а не регрессия; подтверждение прошло только на первом прогоне.
- `t1_stability`: `RW6Z_DIFFS: NotPresent` — возможно, нужна переменная окружения; не проверено.
