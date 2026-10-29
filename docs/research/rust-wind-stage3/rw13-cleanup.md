---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "RW-13: что удалено из старого GD/GLSL-кода ветра, какие тесты и генераторы ушли вместе с ним, что оставлено и почему."
conclusion: "Удалены thermal_field, air_thermals, storm_field, wave_field, cloud_physics, gust_spectrum, GPU-путь (air_gpu, air_gpu_job, air_runtime, air_picard_job, air_phase_job, air_poisson_job, air_multigrid) и шейдеры air_*.glsl, а также мёртвые зависимости (air_clipmap, air_window_*, air_phase*, field_turbulence, air_field_cache, cloud_field*). Эталоны для cargo остаются файлами; генераторы, требовавшие удалённый код, убраны, опорная ревизия GD — по docs/contracts/rust-wind/fixtures-tolerances.md."
data: ""
applied_in: ""
related: ["docs/contracts/rust-wind.md"]
---

# RW-13: уборка старого кода ветра

## Удалено (scripts/atmosphere)
- Заявленное: thermal_field, storm_field, wave_field, cloud_physics, gust_spectrum; air_model/air_thermals, air_gpu, air_gpu_job, air_runtime, air_picard_job; все air_model/*.glsl (+ .import).
- Нужное только им (после обхода ссылок): air_phase_job, air_poisson_job, air_multigrid, air_clipmap, air_window_job, air_window_case, air_phase, air_phase_cpu, field_turbulence, air_field_cache, cloud_field, cloud_field_codec, cloud_field_sources.

## Оставлено
air_case, air_baked_field, air_field_set, wind_field, air_zi_terrain, wind_model, wind_profile, atmo_thermal, cloud_model, ground_field, dust_model — их использует фасад или не тронутые файлы (air_place, air_place_data). Константы запечённого поля (шаг области, допуски условий), жившие в AirRuntime, перенесены в AirBakedField.

## Тесты
Удалены целиком тесты GPU-пути, термиков, облачного поля, кеша поля, фаз, окон, порядка загрузки (test_load_order опирался на ключ кеша AirRuntime), контракт модели воздуха test_air_contracts (AirClipmap/AirWindowJob/AirRuntime), test_storm_rarity, test_start_weather_ref. В test_air_place убраны проверки против эталонов Пикара и подготовки на AirRuntime/AirWindowCase (остались поверхность, вода/лёд, уклон). test_rust_wind_purity: список файлов реализации обновлён. Часть утрат покрывает cargo (terms_*, acceptance).

## Генераторы
Удалены tools/wind_fixtures/{gen_fixtures,run.sh,verify.sh,check_k01.py,day_dump}, tools/weather/storm_rarity, tools/shots/cloud_field_shot и скрипты RW-10d/10e/10f/11b/11d/11f/12d, расширявшие или вызывавшие удалённое. Данные эталонов остаются; пересъёмка — на опорной ревизии GD (fixtures-tolerances.md).

## Попутно
Починены давние ошибки разбора: tools/shots/loading_screen_shot (Game.wind_stage_key), pendulum_pose_shot (make_glider).

## Граница
Комментарии с именами старых классов остались в air_place.gd и weather_model.gd (dont_touch) — проверка old_refs их видит.
