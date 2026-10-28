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
| RW-12b | `rust/dp-air/src/field/weather_core.rs` `sun_elevation_deg`, `weather/tables.rs` `seg` | эмуляция f32 (`Vector2` в GD) ради совпадения ~1e-7; функция общая с полем | полный T1 поля (`acceptance_release`) в итоговом прогоне; прогон для сведения — job `rw12b-acc` |
| RW-12b | `rust/dp-air/src/field/weather_core.rs` | `WeatherModelCfg` += `raw`, `altitude_gain_per_km` (из `atmosphere.json`) | то же |
| RW-12b | `rust/dp-air/src/weather/climate.rs` `PlaceCtx` | += `utc_offset_h`, `start_msl_m` (NaN — не задано); `gain_per_km` зависит от высоты старта | RW-12c/RW-10e: откуда берётся `start_msl_m` в игре — сверить с `_f_weather_ctx` |
