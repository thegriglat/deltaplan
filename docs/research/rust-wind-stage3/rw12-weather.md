---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-8a: разбор RW-12 (погода из прогноза, AtmoDay, коэффициенты): что есть в крейте, чего нет, климат места, эталоны."
conclusion: "Новый код ≈ 735 строк GD → ≈ 900 Rust; в крейте есть diurnal_state, sky_params, день для поля; нет derive, td_day, AtmoDay, коэффициентов; нужен полный ClimateGrid.place (W5)"
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3-path.md", "docs/research/rust-wind-stage3/fixtures.md", "docs/guide/atmosphere.md", "docs/contracts/rust-wind/input.md"]
---

# RW-12: погода из прогноза и ход дня (RW-8a)

Строки — `scripts/atmosphere/…` (`feature/rust-wind`, 2026-10-29); «Rust» — `rust/dp-air/src/…`.

## Исходники

| файл | строк | что |
|---|---|---|
| `weather_model.gd` | 541 | `derive` 100–260 (прогноз → словарь погоды: высота термиков и кромка, сила/размер/частота, облака по запасу, волна, N Брента–Вяйсяля), `diurnal_state` 289, `td_day` 366, `td_noise` 390 (splitmix64), `_apply_heat` 429, `haze_k_rh` 419, `cirrus_base_cover` 59, `_sun_elevation` 261, `ground_context` 75, `typical_max_c` 30, `sun_block_cover` 478, таблицы `interp_rows/lerp_table/monthly` 490–540 |
| `atmo_day.gd` | 113 | ход дня: `hour_at` 46 (часы места с зажимом `world.time.min_hour…max_hour`), `weather_at` 51 (шаг `quantum_h`), `bracket` 56 (линейно между шагами), `value_at`, `sun_at`, `source_at`, `rebase`, `sun_direction` 95 |
| `atmosphere.gd` | ≈ 270 | `_cache_coefficients` 604 (≈ 50 коэффициентов суммы), `_apply_day` 443, `_update_weather` 398, `_blend` 424, `_wind_conditions` 1293, `get_insolation` 1286, фасадная сборка: `_f_weather_ctx` 1530, `_f_resolve` 1560, `_f_water_heat` 1635, `_f_build` 1649, `_f_apply_soft` 1680 |
| `climate_grid.gd` | 340 | сетки ERA5 `data/climate/*.bin` (brotli): `at` 50, `place` 147 (поправки на высоту), `td_gradient`, `belt_gradient` |
| `surface_heating.gd`, `surface_heat.gd` | 98, 216 | инерция прогрева; в крейте перенесены (RW-6c) |

Новое для крейта — ≈ 735 строк GD (`derive` 160, `td_day`+`td_noise` 45, `_apply_heat` 50, влажность/дымка 20, `cirrus_base_cover` 16, таблицы 50, `AtmoDay` 113, коэффициенты 50, мягкая смена/день 100, сборка фасада 70, условия профиля 30, прочее) → Rust ≈ 900 (оценка).

## Что делает `derive`

Прогноз `{temperature_c, wind_speed_kmh, wind_from_deg, sky}` + контекст места `{month, day, lat, lon, valley_msl_m, mean_msl_m}` (+ час) → словарь с теми же ключами, что `configs/weather/*.json` (≈ 40 ключей: `thermal_strength_ms`, `thermal_radius_m`, `thermal_spacing_m`, `thermal_duty`, `background_sink_ms`, `convective_turbulence_ms`, `cloudbase_agl_m`, `cloud_depth_m`, `cb_*`, `overdevelopment_chance`, `wave_strength`, `stability_n_per_s`, `dust_devil_chance`, `thermal_extreme_*`, `cirrus_cover`, `haze_k`, `lens_level_above_crest_m`, …) и `_derived` (≈ 30: `temperature_c`, `dew_point_c`, `z_dry_msl_m`, `z_lcl_msl_m`, `margin_m`, `top_agl_m`, `blue`, `sun_elev_deg`, `sun_k`, `wind_k`, `sky`, `valley_msl_m`, `gain_per_km`, `heat`, `soft`, `rh`, …). Климат — `ClimateGrid.place` (`td_c`, `td_sd_k`, `t700_c`, `z700_m`, `trop_m`, `wr → gain_per_km`, `hcc`, `tx_c`, `dtr_k`, `src` с флагами сеток).

Потребители словаря вне суммы ветра: `weather()` (`cirrus_cover`, `dust_devil_chance`, `lens_level_above_crest_m`, `_derived.valley_msl_m`, `sky`, `haze_k` — `dust_devils.gd`, `cloud_shadow_map.gd`, `cirrus_layer.gd`, `cloud_layer.gd`, `gust_dust.gd`), сигналы `weather_changed` (перестройка) и `weather_updated` (мягко) → W3 `weather_version()` и `weather_rebuild_version()`.

## Входы

- Условия (W5): `forecast{temperature_c, wind_speed_kmh, wind_from_deg, sky}`, `start_hour`, `speed`, `quantum_h`, `wind_ref{ref_msl, gain_per_km}`, `overrides{thermal_spacing_m}`, `blend_s`, `rebuild`, `inflow_mode`; вид «эталон» — готовый словарь пресета (`derive` не нужен, `day == null`).
- Конфиги: `weather_model.json` (≈ 40 таблиц), `weather/*.json`, `atmosphere.json` (коэффициенты суммы — все слагаемые читают их), `surface_heat.json`, **`world.json`** (`time.min_hour 6`, `max_hour 21`, `min_light_elevation_deg 2`, `utc_offset_h` — в W5 в списке имён нет; в Rust `hour_at` без зажима, `weather_core.rs:257`).
- Место: `loc.{lat, lon, month, day, utc_offset_h, climate, climate_lag}` и растр высот (`ground_context`: 15 × 15 проб в круге 10 км, процентиль долины, средняя — в крейте `weather_core.rs:298`).
- **Пробел:** `loc.climate` (W5 v3) содержит только `tx_c, dtr_k, z_cell_m, has_hh1, has_hh5`; `derive` и `Atmosphere.set_wind` требуют ещё `td_c, td_sd_k, t700_c, z700_m, trop_m, gain_per_km (wr), hcc` и флаги `src.hh1/hh2/hh5/hh6` (запасные значения при отсутствии сеток). Либо расширить заголовок (W5 v8: `loc.climate_full`, считает фасад), либо отдать крейту сетки (файловый доступ — противоречит W5 «крейт файлы климата не читает»). Рекомендация — расширить заголовок: сетки читает `ClimateGrid` в GD один раз при сборке `AirPlaceData`.

## Выходы

Словарь погоды на момент (`weather_json`), `AtmoDay`-поведение (`weather_at(t)`, `bracket(t)` для плавных величин), коэффициенты суммы на момент (`bg_sink`, `conv_amp`, `mech_k`, `edge`, `insolation`, `cloudbase_agl`), `sun_state` (направление на солнце + прогрев), `sun_at(t)`, условия профиля ветра (`sun_elev_deg`, `cover`) → RW-9, `source_at` → RW-10c, `cloudbase_msl` (RW-11).

## Состояние во времени

- `AtmoDay` — кеш погоды по номеру шага (ограничен 512 записями), чистая функция `t`; значения плавных величин берутся **на сетке состояния** (`state_update_interval_s = 0,1 с`; на начале интервала обновления `refresh_interval_s = 1 с`): `_apply_day(slot·интервал)` — точное совпадение с эталонами требует той же дискретизации (разница до 0,1 с атмосферного времени = 0,1·`speed` с часов; при `speed = 60` — до 6 с часов).
- Мягкая смена без дня (`day == null`, `_update_weather`): экспоненциальное приближение за `blend_s/3`; повторное `lerp(1 − exp(−dt/τ))` складывается точно — шаг кадра результат не меняет.
- Пересборка при `rebuild`/смене условий: `set_conditions` (W5) решает, пересоздавать ли воздух.

## Случайность

Нет RNG. `td_noise` — splitmix64 и Бокс — Мюллер (целочисленная арифметика, портируется точно; GDScript `int` — 64 бит со знаком, умножение с переполнением — в Rust `wrapping_mul`).

## Что уже есть в крейте (`field/weather_core.rs`)

`WeatherModelCfg::from_value` (`:120`; параметры, нужные полю — часть ключей), `diurnal_state` (`:483`, `diurnal_state_amp :420`), `sky_params` (`:160`), `typical_max_c` (`:406`), `diurnal_range_k` (`:413`), `monthly` (`:343`), `season_index` (`:358`), `Ctx`/`ground_context` (`:265,298`), `WeatherInputs::from_conditions` (`:225`), `Day` и `day()` (`:513,561`: `z_i`, θ̄(z)), `water_mean_air_c` (`:619`), `sun.rs` (позиция солнца NOAA), `surface_heat.rs` (поток тепла), `wind_profile.rs`. **Нет:** `derive`, `td_day`/`td_noise`, `_apply_heat`, `haze_k_rh`, `cirrus_base_cover`, `AtmoDay` (в т. ч. зажим часов), `_cache_coefficients`, мягкая смена/`_blend`, `weather_json`/`weather_version`, `sun_state` с прогревом, `interp_rows/lerp_table` (кроме `monthly`).

## Эталоны

Прогноз и ход дня — **только** `ongudai_day_1…3` (проверка косвенная: термики, ядра, облака). Словарь погоды (`derive`) в эталонах **не лежит** (в `desc.json` только `cloudbase_msl`; `extra.applies[]` — час, `inflow_k`, причина). Для RW-12 нужен прямой эталон: дамп `WeatherModel.derive` по сетке (прогнозы × места × часы) и `AtmoDay.bracket`/`sun_at` — карточка RW-12b (красные тесты первым шагом), генератор в `tools/wind_fixtures/`. Тесты GD, ложащиеся в cargo: `test_weather_model.gd` (271 строка, 16 функций: опорные прогнозы дают эталоны `configs/weather/*`, монотонность, голубой день, весна, волна выкл., детерминизм, скорость), `test_weather_day.gd` (ветер прогноза на старте и рост с высотой; ход дня — мягкое обновление), части `test_air_place.gd` (контекст погоды поля — уже в `weather_core`).

## Риски

1. **Климат** (см. «Входы»): без полной ячейки `derive` не воспроизвести — блокер RW-12b, решение по W5 v8 до начала.
2. **Дискретизация хода дня** (0,1 с / 1 с / 60 с-кванты `quantum_h`): расхождение в пределах допусков, но ядра рождаются по погоде в **начале цикла** (`weather_at(t_start)`), поэтому квант погоды влияет на число/силу ядер.
3. **Два вида условий.** Пока RW-12 не сделан, «прогноз» в крейте невозможен: RW-8…11 разрабатываются на «эталоне» (готовый словарь пресета, `day == null`) — покрывает `ongudai_{medium,strong,wave}` и `synth_*`, не покрывает `day_*`.
4. **Зажим часов** (6…21 по `world.json`) есть в `AtmoDay`, в `hour_at` крейта нет — исправить при переносе (поле считалось без зажима; на старте вечером после 21 ч разница).
5. **Мягкая смена пресета** (`set_conditions` вида «эталон» с `blend_s`) — используется в превью и тестах, не в игре; можно перенести последней.
