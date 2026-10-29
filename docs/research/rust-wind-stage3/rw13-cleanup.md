---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "RW-13: ревизия до удаления, таблица файлов (удалён/оставлен, кто зовёт), удалённые тесты и непокрытые cargo проверки, изменённые manifest, хвосты координатору."
conclusion: "Удалены thermal_field, air_thermals, storm_field, wave_field, cloud_physics, gust_spectrum, GPU-путь (air_gpu, air_gpu_job, air_runtime, air_picard_job, air_phase_job, air_poisson_job, air_multigrid) и шейдеры air_*.glsl, а также мёртвые зависимости (air_clipmap, air_window_*, air_phase*, field_turbulence, air_field_cache, cloud_field*). Эталоны для cargo остаются файлами; генераторы, требовавшие удалённый код, убраны, опорная ревизия GD — по docs/contracts/rust-wind/fixtures-tolerances.md."
data: ""
applied_in: ""
related: ["docs/contracts/rust-wind.md"]
---

# RW-13: уборка старого кода ветра

**Ревизия feature/rust-wind до удаления: `a5d9387c3`.** Любой удалённый файл — `git show a5d9387c3:<путь>`.

## Файлы: удалён / оставлен — почему (кто зовёт)

| Файл | Итог | Почему / кто зовёт |
|---|---|---|
| atmosphere/thermal_field.gd | удалён | заявлен; ветер — в крейте |
| atmosphere/storm_field.gd, wave_field.gd, gust_spectrum.gd | удалены | заявлены; звал только ThermalField/FieldTurbulence |
| atmosphere/cloud_physics.gd | удалён | заявлен; звал ThermalField |
| air_model/air_thermals.gd, air_gpu.gd, air_gpu_job.gd, air_runtime.gd, air_picard_job.gd, air_*.glsl (+.import) | удалены | заявлены (GPU-путь) |
| air_model/air_phase_job.gd, air_poisson_job.gd, air_multigrid.gd | удалены | звал только AirGpu/AirPicardJob |
| air_model/air_clipmap.gd, air_window_job.gd, air_window_case.gd | удалены | звали AirRuntime, AirGpu и тесты окон |
| air_model/air_phase.gd, air_phase_cpu.gd | удалены | звали тесты фаз и GPU-путь; wind_field_debug.gd упоминает AirPhase только в комментарии |
| atmosphere/field_turbulence.gd | удалён | звал AirCase только в комментарии; GustSpectrum — удалён |
| atmosphere/air_field_cache.gd | удалён | звал AirRuntime; кеш полей удалён в RW-P12 |
| atmosphere/cloud_field.gd, cloud_field_codec.gd, cloud_field_sources.gd | удалены | звал CloudPhysics/ThermalField |
| air_model/air_case.gd | оставлен | зовёт air_place.gd (dont_touch, RW-14f/g), wind_profile.gd, air_baked_field.gd |
| air_model/air_zi_terrain.gd | оставлен | зовёт air_case.gd |
| air_model/air_baked_field.gd | оставлен | зовут atmosphere.gd (load_bytes), air_place_data.gd; константы AirRuntime перенесены в него |
| air_model/air_field_set.gd, wind_field.gd | оставлены | зовёт atmosphere.gd (снимок поля фасада) |
| wind_model.gd, wind_profile.gd | оставлены | зовут air_case.gd, weather_model.gd |
| atmo_thermal.gd, cloud_model.gd, dust_model.gd, ground_field.gd | оставлены | зовут визуал облаков, пыль, weather_model/atmo_day |
| weather_model.gd, atmo_day.gd, surface_heat*.gd, climate_grid.gd, air_place_data.gd, air_place.gd | не тронуты | dont_touch (RW-14f/g); в air_place.gd и weather_model.gd остались комментарии со старыми именами — old_refs их не считает |

## Удалённые тесты и проверки, которых нет в cargo
Перенесено на фасад: живая часть test_air_contracts → `tests/contracts/test_air_field_contracts.gd` (C1 формат эталона, C3 WindField, C4 AirFieldSet/turb_at/ключи, C6 версия поля, C8 blend). Проверка «без поля вертикаль 0» ослаблена до |w| < 0,05: крейт даёт малые добавки.

Удалены без замены (проверок нет в cargo, перечень построчно):
- test_air_contracts: test_contract_versions (версии air-model.md), test_thd_in_state_keys, C2 (test_c2_air_case_grid, cell_geometry, surface_input, inflow_scale, params_match_reference — AirCase и параметры решателя против эталона), C5 (подпись AirThermals, сетевая схема), C7 (форма AirClipmap/AirWindowJob), C9/C10 (форма AirRuntime, needs_recompute, slot_hour).
- test_air_place: сверка домена Пикара с эталонами AM-01 (test_domain_input_vs_reference), доли классов клетки (test_cell_fractions_synthetic), детерминизм снимка поверхности (test_surface_determinism_ongudai), z0 клеток и карта z0 окна, побитность параллельной подготовки.
- test_load_order (FL-10): порядок «старт и поле воздуха до объектов мира», ключ кеша поля.
- test_air_cache, test_fast_load_k1: кеш полей на диске (AirFieldCache).
- test_zi_terrain, test_subsidence: z_i по рельефу и опускание горно-равнинной циркуляции в GD-AirThermals (в крейте — terms_thermal*.rs, но без проверки CLF-К6 по α).
- test_cloud_field*, test_cloud_field_k1–k4, test_cloud_field_perf: GD-поле облачности (в крейте — terms_thermal_cloud.rs).
- test_air_phase, test_air_window_case, test_air_runtime*, test_air_gpu_*, test_air_picard_*, test_air_hybrid_gpu, test_air_window_gpu, test_air_baked_gpu, test_air_cache_gpu, test_air_prep_parallel_gpu, test_air_thermals*, test_start_regression_gpu, test_start_weather_ref (условия AirRuntime wind_ref), test_storm_rarity (слияние выбросов Cb — в крейте terms_storm.rs, статистика по случайным дням — нет).
- test_rust_wind_purity: убраны из списка файлов реализации удалённые.
- rust/dp-air/tests/runtime.rs: constants_match_gdscript_and_configs → constants_match_configs (сверка с GD-файлами убрана, сверка с configs осталась).

## Изменённые manifest (generator_removed_at = a5d9387c3, generator_files_removed — пути)
RW-10d, RW-10e, RW-10f, RW-11d, day_dump (дополнены); RW-11b, RW-11f, RW-12d (созданы минимальные). RW-8/README.md и tests/fixtures/wind/README.md — пометка об удалённом gen_fixtures. Удалены генераторы: RW-10d (dump_air_thermals.gd/.tscn, run_dump.sh), RW-10e (gen_cases_baked.gd/.tscn, run_cases.sh), RW-10f (gen_cloud_cases.gd, run_cloud_cases.sh), RW-11b (gen_ongudai_wave.gd), RW-11d (dump_clouds.gd, run_dump.sh), RW-11f (dump_cloud_objects.gd/.tscn, run_dump.sh), RW-12d (weather_ref.gd/.sh/.tscn), tools/wind_fixtures (gen_fixtures.*, run.sh, verify.sh, check_k01.py, day_dump.*). Оставлены: RW-10c/dump_source.gd, RW-9/dump.*, tools/wind_fixtures/weather_dump.*, compat_dump.*, weather_ref2.*.

## Прочие инструменты
Удалены: tools/weather/storm_rarity, tools/shots/cloud_field_shot, tools/terrain/{island,volcano}/air_check_run.* и air_check.py (только про старый путь). Починены давние разборы: loading_screen_shot.gd, pendulum_pose_shot.gd; game.gd:614–615 (`tr()` в static, из RW-P13).

## Хвосты координатору (вне скоупа)
- Константы DOMAIN_DX/WIND_TOL_MS/DIR_TOL_DEG/TMAX_TOL_C в air_baked_field.gd продублированы в dp-air/src/field/runtime.rs без сверки (→ RW-16b: сверка или значения из DpAir).
- rust/dp-air/tests/weather_day.rs:2 и docs/contracts/rust-wind/fixtures-tolerances.md:25 ссылаются на удалённые day_dump.sh и gen_fixtures.gd.
- Комментарии в rust/dp-air/src и тестах .rs с путями удалённых .gd (историческая привязка).
