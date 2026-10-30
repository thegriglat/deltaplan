---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-8a: проект карточек подзадач этапа 3 (RW-8b…12z): скоуп, красные тесты, зависимости, параллельность, где сталкиваются правки formula.rs."
conclusion: "16 подзадач; первыми — каркас суммы (8b) и совместимость с Godot (8c); дальше до 4 параллельно; formula.rs правят только 8b и итоговый шаг фасада"
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3-path.md", "docs/research/rust-wind-stage3/rw8-rw9.md", "docs/research/rust-wind-stage3/rw10-thermals.md", "docs/research/rust-wind-stage3/rw11-clouds.md", "docs/research/rust-wind-stage3/rw12-weather.md"]
---

# Проект карточек этапа 3 (RW-8a)

Идентификаторы — рабочие (RW-8a занят этим разбором, поэтому с `b`); переименовывает координатор. Размеры — оценка по чтению кода (строки GDScript в источниках, дни исполнителя), не замер. Тесты — «красные первым шагом» (план, «Тесты»).

## Где столкнутся правки

В `rust/dp-air/src/formula.rs` (1 239 строк) сходятся все слагаемые: структура `Published` (`:84`), `sample_point` (`:936`), методы трейта `cores/clouds/cloud_raster/wave_crests/decompose/background_wind/weather_json/sun_state/cloud_density_many` (`:1159–1239` — сейчас заглушки), `set_static_thermals` (`:1044`), `set_conditions`/`advance_to`/`set_focuses`. Если пять исполнителей правят их одновременно, будут конфликты слияния и несовместимые куски суммы. **Предложение:** первая задача (RW-8b) один раз переносит эти точки в новый модуль `terms/` (`terms::Terms` — снимок слагаемых; `terms::sum` — порядок суммы из `air_velocity_at`; слоты `turb`, `analytic`, `thermal`, `extra` с нулевыми заглушками; `terms::decompose` — запись слагаемых W7 по `T_NAMES`), а `formula.rs` дальше правит только RW-12z (переход фасада). Остальные задачи добавляют файлы в `terms/<своё>/` и заменяют заглушку своего слота. Общие файлы: `terms/mod.rs` (список модулей — по одной строке на задачу, конфликт тривиален), `Cargo.toml` (без новых зависимостей), `tests/` — отдельные файлы на задачу.

## Карточки

| ID | что | скоуп (Rust / прочее) | красные тесты первым шагом | зависит от | ~GD строк | дни |
|---|---|---|---|---|---|---|
| **RW-8b** | каркас суммы + ветровая рамка | `terms/{mod,sum,frame,decompose}.rs`, правка `formula.rs`; `frame` — профиль ветра (`WindModel.profile/speed_at/speed_at_pos/altitude_factor/vec2_at/dir`, `simple_profile`) на `wind_profile.rs` | сумма с нулевыми слотами = нынешнему `sample_point` побитно; профиль против `synth_*` `analytic` на горизонтальной компоненте без рельефа; `decompose` по `T_NAMES` и инварианты W7 (`Σ vel = total.xyz ± 1e-4`) | — | ≈ 400 (сумма) + 130 | 1,5 |
| **RW-8c** | совместимость с Godot: PCG32, `randf/randf_range`, `hash(Vector2i/Vector3i)`, порт `FastNoiseLite` (OpenSimplex2S 3D, FBM) | `terms/compat/{rng,hash,noise}.rs`; `tools/wind_fixtures/compat_dump.gd` (+ `.sh`), дамп в `tests/fixtures/wind/compat/` | дамп из Godot (значения шума, последовательности RNG, хеши) сравнивается с портом; шлюз «≤ 1e-6» (`godot-compat.md`); не сошлось за день — `contract:` | — | ≈ 350 порт | 2 |
| **RW-8** | `FieldTurbulence` + `GustSpectrum` + `WindModel.gust_unit` + рывки слоя смешения; слот `turb` | `terms/turb/{sigma,spectrum,gust,sep}.rs` | T3 (дисперсия, спектр, масштабы MIL-HDBK-1797, σ_u ≠ σ_v по длинной выборке); σ против `ongudai_*` (`sigma[turb]`, при нулевых RW-10/11-входах — по формуле поля); `taylor_stretch`; побитность шума, если порт принят | 8b, 8c | ≈ 600 | 3–4 |
| **RW-9** | `GroundField` (склон, линия тени, превышение гребня), аналитика, склоновый подъём, подветренный поток, полоса края `a < 1`, режим `off`, `background_wind` | `terms/analytic/{ground,ridge,lee,strip,off}.rs` | `synth_*` `analytic/ridge/gust` MEAN и σ; `lee`-точки `ongudai_*`; `test_wind_profile_simple` в cargo; нет разрыва на краю полосы (T2); случай RW-2c `off` | 8b (рамка), 8c (шум `gust_unit` для FULL) | ≈ 680 | 2–3 |
| **RW-10c** | сила источника термика из растров места | `terms/thermal/source.rs` | `thermal_source_strength` против дампа GD по сетке точек Онгудая/синтетики (допуск — по `rw10-thermals.md`, риск 3); вода/ночь/край | — (есть `mix_flux`, `SurfaceHeating`) | ≈ 250 | 1,5 |
| **RW-10b** | `AtmoThermal`, жизнь по клеткам (аналитический путь), статичные, `sample`, фон, `cores` | `terms/thermal/{life,cells,profile,sample,statics,cores}.rs` | синтетические случаи: `thermal` MEAN в точках без облаков; ядра (`desc.json`); детерминизм `start_at(t)` = прогон с 0 (T6); `test_atmosphere` термики | 8b, 8c, 10c | ≈ 900 | 3 |
| **RW-10d** | `AirThermals.build` (источники из поля) | `terms/thermal/air/{columns,pick,owners,sources,expected}.rs` | `test_air_thermals*` (параллельно = последовательно побитно), `test_subsidence`, поток массы пузырей = потоку поля; источники `ongudai_*` против ядер `desc.json` | 8c, 10c, поле (есть) | ≈ 1 150 | 3–4 |
| **RW-10e** | источники поля в жизни термика, «между», охват, пересборка по ключу, фокусы | `terms/thermal/{from_field,focus}.rs` | `thermal` и `cores` на `ongudai_*` вне облаков; `ongudai_day_*` — после 12b | 10b, 10d, 12b | ≈ 450 | 2 |
| **RW-11b** | `WaveField`, `wave_crests`, слот `wave` | `terms/waves/` | `synth_wave`, `ongudai_wave` (`wave` ≤ 8 м/с, `crests` из `desc.json`); `test_wave` | 8b (рамка), погода пресетом | ≈ 250 | 1,5 |
| **RW-11c** | `StormField`, `CloudModel.stage/size/center` (Cb), слот `storm` | `terms/storm/` | `synth_storm` (`storm` 182 точки-момента), `test_storm_rarity` | 10b | ≈ 350 | 2 |
| **RW-11d** | `CloudField`, `CloudFieldSources`, `CloudPhysics`, слот `cloud`, `cloud_raster`, `clouds`, `cloud_density_many`; замыкание крючков RW-10 | `terms/clouds/` | `test_cloud_field*`, `test_cloud_suck`, `test_cloud_start`; растр против `cloud_raster` GD на фикстуре; повторная сверка `thermal` в `above_base` | 10b, 10e, 12b | ≈ 1 000 | 4–5 |
| **RW-11e** | W6 v4 (записи Cb, волн, гроз, момент `t`), `cloud_layer.gd` на W6 | `scripts/atmosphere/cloud_layer.gd`, `cloud_model.gd` (выбор), `tests/` | `test_cloud_fade`, `test_cloud_layer_history`, `test_cloud_select_chunked` зелёные на записях | 11c, 11d; W6 v4 | ≈ 300 GD | 2 |
| **RW-12b** | эталон погоды (дамп `derive`/`AtmoDay`) + `derive`, `td_day`, `_apply_heat`, `haze`, `cirrus_base_cover` | `terms/weather/{derive,climate,heat}.rs`; `tools/wind_fixtures/` | `test_weather_model` (16) в cargo + дамп; W5 v8 (климат) | W5 v8 | ≈ 400 | 2 |
| **RW-12c** | `AtmoDay`, коэффициенты суммы, мягкая смена, `weather_json`/версии, `sun_state` | `terms/weather/{day,coeffs,soft}.rs` | `test_weather_day`; кванты 0,1/1/60 с; `weather_version` растёт | 12b | ≈ 335 | 1,5 |
| **RW-10f** | замыкание: подсос и тень облаков в `thermal`, сверка `above_base` | правки `terms/thermal/` | `thermal` в точках `above_base` и в 250 м под основанием; ядра с облаком | 11d | — | 1 |
| **RW-12z** | **переход фасада** (одним шагом): `sample_many/decompose/cores/clouds/cloud_raster/wave_crests/background_wind/weather/sun_state/cloud_density_many` → `DpAir`; удаление GD-слагаемых из горячего пути, `field_export` потребители; `GustDust`, `mean_wind_at`, `thermals_near` | `scripts/atmosphere/atmosphere.gd`, `formula.rs`, `dp-gd` | T7 (набор игровых тестов фасада на Rust), тест чистоты, T1 итога | всё выше | — | 3 |

Итого ≈ 7 500 строк GD, ≈ 37 исполнительских дней (оценка). Критический путь при ≤ 4 параллельных: 10c → 10d → 10e → 11d → 11e → 12z ≈ 18–19 календарных дней.

## Что нужно от координатора до запуска (контракт)

Правки W2/W3/W4/W5/W6/W7 — «Пробелы контракта» главного документа: W5 v8 (полный климат места; `world.json` в списке конфигов; необязательное `loc.climate` расширение), W6 v4 (записи Cb/гроз, момент `t ≤ now`, `wave.enabled`), W2/W4 (поверхностный порыв `GustDust`, режим `SAMPLE_BASE`), W8 v2 (допуск числа ядер, правила для `above_base`). Менять их — только координатору (CLAUDE.md проекта).
