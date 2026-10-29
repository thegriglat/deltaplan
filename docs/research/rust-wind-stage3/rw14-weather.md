---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "RW-14a: проект переноса погоды в dp-air — инвентарь, потребители, контракт DpWeather, эталоны, задачи RW-14b…h, чистота крейта."
conclusion: "Ядро погоды (derive, ход дня, коэффициенты, поток тепла, ground_context, вода) уже в крейте и сверено с GD; осталось: чтение сеток климата (ClimateGrid.at), статический класс DpWeather для вызовов без места (меню, цели, достижения, дымка), перевод ≈ 14 живых файлов, снятие недостающих эталонов, удаление ≈ 2000 строк GD и чистка dp-air от игровых имён; 7 задач RW-14b…h"
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3/rw12-weather.md", "docs/research/rust-wind-stage3/rw12z.md", "docs/research/rust-wind-stage3/fixtures.md", "docs/research/rust-wind-stage3/godot-compat.md", "docs/contracts/rust-wind/dpair.md", "docs/contracts/rust-wind/facade.md", "docs/contracts/rust-wind/input.md", "docs/plan/rust-wind.md"]
---

# RW-14: перенос погоды в крейт (проект, RW-14a)

Решение пользователя 2026-10-30: до сдачи модуля погода — в `dp-air`; Godot только опрашивает; второй реализации в GDScript нет; эталоны снять с GD-кода до удаления; порядок с RW-13 — на усмотрение координатора. Критерий чистоты (того же дня): `dp-air` не знает игры (раздел «Чистота dp-air»). Документ — проект, код не правился. Строки — `feature/rust-wind` на 2026-10-30 (`e64fe67e7`).

Главный вывод: RW-12 уже перенёс почти всё вычисление (`rust/dp-air/src/weather/`, `field/weather_core.rs`, `field/surface_heat.rs`) и сверил с дампами GD. Не перенесено другое: **(1)** сетки климата (`ClimateGrid.at`: читает файлы и распаковывает brotli) — крейт берёт готовую ячейку у GD; **(2)** вызовы погоды **без загруженного места** (меню, цель полёта, подсказка температуры, достижения, дымка) — у них нет пути в крейт, они зовут GD-статики; **(3)** сам GD-код остаётся и живёт (≈ 2200 строк в 6 файлах). Эталоны по этим двум дырам не сняты.

## Инвентарь

Размеры — строки `.gd`; «в крейте» — где реализовано и чем сверено (подробно — «Есть в крейте»).

| GD | строк | что делает | судьба |
|---|---|---|---|
| `scripts/atmosphere/weather_model.gd` (`WeatherModel`) | 542 | `derive` (прогноз → ≈ 40 ключей погоды + `_derived`), `diurnal_state` (суточный ход, закат), `td_day`/`td_noise`, `haze_k_rh`, `cirrus_base_cover`, `sun_block_cover`, `sky_params`, `typical_max_c`, `diurnal_range_k`, `ground_context`, `reference_context`, `monthly`/`lerp_table`/`interp_rows`, `config` (чтение `configs/weather_model.json`) | вычисление — в крейте; GD удалить; `config()` делится (см. ниже) |
| `scripts/atmosphere/atmo_day.gd` (`AtmoDay`) | 113 | часы места по времени воздуха, погода по квантам `quantum_h`, `bracket`, `sun_at`, `source_at`, `rebase`, `sun_direction` | в крейте (`weather/day.rs`); GD удалить |
| `scripts/atmosphere/surface_heat.gd` (`SurfaceHeat`) | 216 | поток тепла (`shortwave`, `bowen`, `land_flux`, `water_flux`, `mix_flux`), `water_temp_c`, `air_temp_c`, `air_density_factor` | поток — в крейте (`field/surface_heat.rs`), `water_temp_c` — `weather_core.rs:668`; **`air_temp_c` публично нет** (`lapse` приватна, `weather_core.rs:626`); GD удалить |
| `scripts/atmosphere/surface_heating.gd` (`SurfaceHeating`) | 98 | инерция прогрева по классам поверхности (`directions`, `built_night`) | в крейте (`field/surface_heat.rs:312`); потребители GD — `game.gd:123`, `terrain.gd` |
| `scripts/atmosphere/climate_grid.gd` (`ClimateGrid`) | 340 | `at` (4 сетки ERA5 `data/climate/*.bin`, brotli, int16; билинейно по ячейкам и по двум месяцам, пропуски −32768), `place` (поправки на высоту долины), `td_gradient`, `belt_gradient`, `season_index`, `band_index`, `set_paths` | `place` и градиенты — в крейте (`weather/climate.rs`, `weather_core.rs:376`); **`at` — нет** (крейт «файлы климата не читает», W5) |
| `scripts/atmosphere/air_place_data.gd` (`AirPlaceData`) | ≈ 400 | данные места для крейта: растры (высоты, вода, класс, влажность), заголовок W5, `fill_climate` (ячейки климата в заголовок), `fill_crate_inputs` (id, погода стартов, хеши, запечённые файлы), `from_terrain`/`from_functions`/`terrain_snapshot` | растры берёт крейт (`load_place`); сборка из рельефа игры — остаётся в GD (граница); `fill_climate` уходит с `ClimateGrid.at` в крейт |
| `scripts/atmosphere/air_model/air_place.gd` (`AirPlace`) | 979 | вход GD-решателя: `domain_case`, `context`, `day`/`theta`/`gamma`, `block_mean`, `water_fraction`, `cell_surface`, `cell_z0`, `surface_flux`, **снимок поверхности** `surface_start`/`surface_of`/`Surface` | всё, кроме снимка поверхности, — в крейте (`weather_core.rs`, `place_input.rs`, `case_prepare.rs`); GD-решатель умирает в RW-13; **снимок поверхности (классы и влажность из карт игры) — остаётся в GD** |

Фасадная часть `atmosphere.gd` (`_cache_coefficients`, `_apply_day`, `_blend`, `_wind_conditions`) уже заменена `WeatherState`/`Coefficients` (RW-12c); в GD остались вызовы `DpAir`.

**Что держит `WeatherModel.config()`.** Это просто `Config.get_config("weather_model")`: смесь физических параметров (таблицы температур, климат, `diurnal`, `heating`, `upper_air`, `hcc_sky`, …) и меню (`ui.temperature_c`, `ui.compass_points`, `sky.options`). Физика — в крейт (она уже приходит туда текстом через `configure`), меню — в GD (границы ползунков; крейт их не должен знать, кроме одного места: `typical_max_c` зажимает результат в `ui.temperature_c`, `weather_core.rs:421` — см. «Предложение контракта», п. 4).

## Потребители

Живые вызовы вне удаляемого GD-решателя (файл: что берёт).

| потребитель | что берёт | без места? | нужно от крейта |
|---|---|---|---|
| `scripts/game/game.gd:126, 394` (`AtmoDay.new()` как часы), `:568` (`quantum_h`) | константа `quantum_h`; часы по `hour_at(t)` | да (до воздуха) | `DpWeather.quantum_h()`; `hour_at(start_hour, speed, t)` — свободная функция |
| `game.gd:573` | `ClimateGrid.place(...).gain_per_km` в `wind_ref` | да | `gain_per_km` считает крейт сам из климата и `ref_msl` (W5: ключ `gain_per_km` необязателен) |
| `game.gd:676` (`_weather_context`) | `ground_context(terrain.height_at, …)` + дата, широта, пояс; используется для `SurfaceHeat.water_temp_c`/`air_temp_c`, подсказок | до воздуха | контекст места из растра: `DpAir.place_context()` после `load_place`; до него — `DpWeather.ground_context` по растру высот места (тот же, что получит `load_place`) |
| `game.gd:729–735, 2264` | `SurfaceHeat.water_temp_c`, `air_temp_c` (контекст воды для `Terrain.set_water_heat`; порог снежных флагов `air_temp_c_at`) | да | `DpWeather.air_temp_c`, `water_temp_c` |
| `game.gd:1797` | `sky_params(sky).cover` | да | `DpWeather.sky_params(sky)` |
| `game.gd:183, 665` | `air.weather()` (`haze_k` и др.) | нет | уже `DpAir.weather_json()` |
| `scripts/game/flight_settings.gd:148` | `typical_max_c(month, day, {}, {lat, lon})` — начальная температура в меню | да | `DpWeather.typical_max_c(month, day, lat, lon)` |
| `flight_settings.gd:163, 170` | `config().ui.temperature_c/…` | да | остаётся в GD (меню) |
| `scripts/ui/flight_setup_screen.gd:398` | `typical_max_c` — подсказка «обычно днём…» | да | то же |
| `scripts/goals/goal_estimator.gd:23–48` | `derive(forecast, ctx, wc, start_hour)`, `diurnal_state(...).sunset_h`, `reference_context` | да (рельефа ещё нет) | `DpWeather.derive`, `DpWeather.sunset_h` / `diurnal_state`, `reference_context` |
| `scripts/game/achievement_feed.gd:196–200` | `temp_at_altitude(w, alt, month, day)`: `config().upper_air`, `monthly` | нет (есть `weather()`), но формула — погода | `DpWeather.temp_at_altitude(weather_dict, alt_msl, month, day)` |
| `scripts/world/sky_environment.gd:384` | в комментарии `haze_k_rh`; `haze_k` приходит из `air.weather()` | нет | ничего (комментарий) |
| `scripts/world_objects/egg_place.gd:42` | `ground_context(terrain.height_at, радиус/число точек/процентиль из своего конфига).valley_msl_m` | да | `DpWeather.ground_context_fn` не нужен: пасхалке достаточно высоты долины — см. «Предложение контракта», п. 6 |
| `scripts/game/start_weather.gd:36` | `config().sky.options` | да | остаётся в GD (меню) |
| `scripts/ui/…`, `tests/ui/test_language.gd:76` | `config().sky.options` | да | остаётся в GD |
| `scripts/game/game.gd`, `scripts/atmosphere/atmosphere.gd:311, 460`, `scripts/game/calm_air.gd:62` | `AirPlaceData` (+ `AirPlace.Surface`) | — | остаётся (граница GD→крейт), теряет `fill_climate` |
| `scripts/terrain/terrain.gd:760, 1168` (`SurfaceHeat.mix_flux`, `config`) | сила источника термиков от потока тепла — путь **GD-реализации** (`thermal_source_strength_at`, `set_water_heat`, `set_class_sun`) | — | единственный живой вызов — `AirPlaceData.terrain` (`air_place_data.gd:393`, «переходное, только реализация gd»); после RW-13 мёртв — удалить вместе с `_update_water_heat` (`game.gd:741`) и `SurfaceHeating` в `game.gd`; прогрев поверхности для поля считает крейт (`WeatherState`/`SurfaceHeating`) |
| `scripts/atmosphere/atmosphere_preview.gd:98`, `scripts/world_objects/world_objects_preview.gd:80` | `AirPlaceData.from_functions` | — | остаются (превью-сцены), после RW-14d берут климат у крейта |

**Умирает вместе с GD-решателем (RW-12z/RW-13), отдельного перевода не требует** (ссылки только друг на друга и на превью): `air_place.gd`, `air_runtime.gd`, `air_window_case.gd`, `air_clipmap.gd`, `air_case.gd`, `air_zi_terrain.gd`, `air_thermals.gd`, `air_baked_field.gd`, `wind_profile.gd`, `wind_model.gd`, `thermal_field.gd`, `cloud_physics.gd`, `storm_field.gd`, `atmo_fingerprint*.gd`; из `AtmoDay`/`WeatherModel`/`SurfaceHeat`/`ClimateGrid` они держат всё, что не в таблице выше (в т. ч. `sun_block_cover`, `diurnal_range_k`, `block_mean`, `td_gradient`). Перед удалением проверять `grep -rw <Класс>` по `scripts scenes tools tests`: на 2026-10-30 `ThermalField`, `AirThermals`, `AirRuntime`, `AtmoFingerprint` ссылаются только друг на друга и на `.tscn`-превью.

**Тесты и инструменты**, зовущие эти классы: `tests/atmosphere/` (`test_weather_model` — 14 из 16 функций уже в cargo как `gd_*`, `test_weather_day`, `test_surface_heat`, `test_surface_heating`, `test_storm_rarity`, `test_air_place*`), `tests/contracts/test_haze_humidity_contracts.gd` (HH7, `ClimateGrid`), `test_air_place_climate_lag`, `tests/game/{test_forecast_game,test_game_logic,test_achievement_feed}`, `tests/goals/test_goal_estimator`, `tests/terrain/{test_surface,test_relief}`, ≈ 30 файлов `tools/`. Дампы `tools/wind_fixtures/*`, `tools/research/rust_wind/dump_*.gd` работают только пока жив GD.

## Есть в крейте

Сверено с дампами GD (допуск `1e-6 + 1e-5·|ref|`) тестами `rust/dp-air/tests/`: `weather_derive.rs` (дамп `rows.jsonl.zst`, 15 функций по видам строк: Онгудай, учебный остров, вулкан, синтетика без сеток, без HH1/HH6, разгар дня, утро/вечер + 14 `gd_*` — порт `test_weather_model.gd`), `weather_day.rs` (дамп хода дня, коэффициенты, мягкая смена, `sun_state`), `weather_core.rs` (дамп контекста, суточного состояния, воды, потока тепла, профиля ветра).

| GD | Rust | проверка |
|---|---|---|
| `derive` | `weather::derive` (`derive.rs:166`) | `weather_derive.rs`, дамп `weather_dump` |
| `td_day`, `td_noise`, `_mix64` | `weather::{td_day, td_noise, splitmix64}` (`noise.rs`) | тот же + вектор splitmix |
| `haze_k_rh`, `cirrus_base_cover`, `sun_block_cover` | `weather::{…}` (`derive.rs:40, 49, 86`) | `weather_derive.rs` (частично косвенно) |
| `monthly`, `lerp_table`, `interp_rows` | `field::weather_core::monthly` (`:352`), `weather::{lerp_table, interp_rows}` (`tables.rs`) | косвенно через `derive` |
| `ClimateGrid.place`, `td_gradient`, `belt_gradient`, `season_index`, `band_index` | `weather::climate_place` (`climate.rs:116`), `belt_gradient` (`weather_core.rs:376`), `season_index` (`:367`), `band_index` (`noise.rs:40`) | `weather_derive.rs`: `dump_climate_*` на ячейках `climate_cells.json` |
| `WeatherModel.diurnal_state`, `typical_max_c`, `diurnal_range_k`, `sky_params`, `ground_context` | `WeatherModelCfg::{diurnal_state, typical_max_c, diurnal_range_k, sky_params}`, `ground_context` (`weather_core.rs:167, 307, 421–497`) | `weather_core.rs` (дамп) |
| `AtmoDay` | `weather::AtmoDay` (`day.rs`) + `WorldTime`, `SunSpec`, `sun_direction` | `weather_day.rs` (дамп `day_dump`) |
| `Atmosphere._cache_coefficients`, `_apply_day`, `_update_weather`, `_blend`, `_wind_conditions`, `get_insolation`, версии, `sun_state` | `Coefficients`, `WeatherState` (`state.rs`) | `weather_day.rs` |
| `SurfaceHeat.shortwave … mix_flux`, `air_density_factor` | `field::surface_heat` (`:140–256`) | поток — косвенно через `weather_core.rs`; **юнит-тестов нет** (`#[test]` в `surface_heat.rs`: 0), порт `test_surface_heat.gd` не сделан |
| `SurfaceHeating` | `surface_heat::SurfaceHeating` (`:312`) | `weather_core.rs:358` |
| `SurfaceHeat.water_temp_c` | `weather_core::water_temp_c` (`:668`), `water_mean_air_c` (`:633`) | `weather_core.rs` (дамп) |
| `AirPlace.context/day/theta/gamma/block_mean/cell_z0/surface_flux`, `WindProfile.apply_to_case` | `weather_core.rs`, `wind_profile.rs`, `place_input.rs` | `weather_core.rs`, `case_prepare.rs` |
| сборка условий `Atmosphere._f_resolve` | `WeatherInputs::from_conditions` (`weather_core.rs:234`) | `weather_core.rs` |
| `AirBakedField` модель/хеш данных места | `field::baked` | `baked.rs` (вне погоды) |

**Нет в крейте** (или нет снаружи):
1. `ClimateGrid.at` — чтение/распаковка сеток; `Climate`-трейт (`weather_core.rs:55`) только принимает готовую ячейку.
2. Публичный вход «без места»: `derive`/`typical_max_c`/`diurnal_state` требуют `WeatherModelCfg`, `PlaceCtx`, `ClimatePlace`, которых у GD нет; все функции доступны только из Rust-кода, ни одна не выведена в `dp-gd`.
3. `air_temp_c` (воздух на высоте z по суточному ходу) и `temp_at_altitude` (профиль для достижений).
4. `reference_context` (опорное место конфига без рельефа) и `noon_elevation_deg` (используется в `derive`? — в Rust есть `sun_elevation_deg`, `weather_core.rs:395`; отдельного `noon_elevation_deg` нет, проверить, нужен ли потребителю).
5. `ground_context` по произвольной функции высоты: в крейте — по растру места (`Place`). GD зовёт её по `terrain.height_at` (непрерывной функции рельефа с несколькими слоями), крейт — по растру 25 м; расхождение не измерено (риск 2).
6. Юнит-проверка потока тепла (порт `test_surface_heat.gd`, `test_surface_heating.gd`).

## Предложение контракта

Не меняет контракты из карточки (W2 v6, W3 v8, W4 v9, W5 v9, W6 v4): это предложения для координатора — новая версия W3 (класс `DpWeather`), W5 (необязательные поля), W4 (чистота). Поток вызовов — `GD → DpWeather (без места)` и `GD → DpAir (с местом)`; оба над одним модулем `dp_air::weather`.

**1. Модуль `dp_air::weather` — публичный API без игры.** Структура `Weather` (неизменяемая, `Arc`), собирается из `Configs` и сеток климата:
- `Weather::new(cfgs: &Configs, grids: ClimateGrids) -> Result<Weather, Error>`; конфиги — те же имена секций, что принимает `configure` (`weather_model`, `surface_heat`, `atmosphere`, `weather/<имя>`; переименование на нейтральные — «Чистота dp-air», п. 2);
- `ClimateGrids::from_bytes([(имя, байты); 4]) -> ClimateGrids` — сетки приходят **байтами** (`FileAccess` в GD, путь знает игра, крейт путей не знает); состояния `data/stub/none` как у GD; нет сетки — запасные значения конфига (`climate.fallback`);
- `Weather::climate_at(lat, lon, month, day) -> ClimateCell` (`ClimateGrid.at`), `climate_place(ctx) -> ClimatePlace` (есть);
- `typical_max_c`, `diurnal_range_k`, `diurnal_state(t_max, hour, ctx)`, `sky_params(sky)`, `derive(forecast, ctx, hour) -> Map` (есть, обернуть), `haze_k_rh(t, td)`, `air_temp_c(hour, t_max, z, ctx)`, `water_temp_c(month, day, z, ctx)`, `temp_at_altitude(weather, alt, month, day)`, `monthly`, `quantum_h`, `hour_at(start_hour, speed, t, world_time)`, `ground_context(raster, …)`.
- Единицы и время — как у W5: °C, м MSL, км/ч в прогнозе (как в меню — это единицы входа, не «меню»), час места десятичный, `NaN` в `hour` = «разгар дня» (как GD), `NaN` в `valley_msl_m`/`utc_offset_h` = не задано.

**2. Класс `DpWeather` (`dp-gd`, `RefCounted`, без состояния кроме сеток).** Методы (все — чистые функции, поток-безопасны; словари — в JSON-строке, один разбор на стороне GD):
`configure(configs_json: PackedStringArray, climate_names: PackedStringArray, climate_bytes: Array[PackedByteArray]) -> int`;
`typical_max_c(month, day, lat, lon) -> float` (NaN lat/lon — таблица `typical_max_c`);
`derive(forecast_json, ctx_json, hour) -> String` (JSON как `weather_json`: ключи пресета + `_derived`);
`diurnal_state(t_max, hour, ctx_json) -> String`; `sunset_h(t_max, ctx_json) -> float`;
`sky_params(sky) -> PackedFloat32Array` (`[cover, sky_heat]`);
`air_temp_c(...)`, `water_temp_c(...)`, `temp_at_altitude(weather_json, alt_msl, month, day) -> float`;
`reference_context() -> String`; `quantum_h() -> float`; `climate_cell(lat, lon, month, day) -> String`.
Нужен один общий экземпляр: меню строит его при старте игры; `DpAir.configure` получает те же конфиги, а сетки — `DpAir.attach_weather(w: DpWeather) -> int` (передаёт `Arc`), чтобы климат не читался и не хранился дважды.

**3. Климат места внутри `DpAir`.** `loc.climate`, `loc.climate_lag`, `loc.climate_cell`, `loc.climate_cell_lag` (W5 v3, v7, v8) удаляются из заголовка: крейт сам берёт `Weather::climate_at(center_lat, center_lon, …)` на дату места и на дату − `round(lag_days)`. `AirPlaceData.fill_climate/_climate_cell` удалить целиком. Эталоны `places/*.json` теряют ключи (`fixtures.md`, строки про `climate_cell*`).

**4. Зажим температуры в диапазон меню.** `typical_max_c` в GD зажимает в `ui.temperature_c` (меню), в Rust тоже (`weather_core.rs:421–425`, `ui_temperature_c`). Нейтральная форма: параметр `temperature_range_c: [min, max]` в `weather_model` (физический предел модели, не меню); GD-меню берёт те же числа из того же конфига (`ui.temperature_c` = диапазон ползунка остаётся в GD). Конфиг не меняется по смыслу, меняется чтение в крейте (читать `limits.temperature_c`, а не `ui.*`).

**5. `gain_per_km` в `wind_ref`.** Сейчас считает и передаёт `game.gd:573` из `ClimateGrid.place`. Предложение (W5 v10): поле `wind_ref.gain_per_km` необязательное; нет — крейт берёт его из `Weather::climate_place(ctx + start_msl_m)`. Тогда `game.gd` не зовёт климат вообще.

**6. Высота долины для пасхалок.** `egg_place.gd` берёт долину по `terrain.height_at` до воздуха. Предложение: `DpWeather.valley_of(samples: PackedFloat32Array, percentile) -> float` — GD сам снимает пробы высоты, процентиль считает крейт (см. риск 2).

**7. Контекст места от крейта.** `DpAir.place_context() -> String` (JSON: `valley_msl_m`, `mean_msl_m`, `month`, `day`, `lat`, `lon`, `utc_offset_h`) после `load_place` — для `_weather_ctx` игры (`game.gd:676`); один источник истины вместо второго расчёта по `terrain.height_at`.

**8. Что остаётся в GD (граница).** Сбор растров места из рельефа игры (`AirPlaceData.terrain_snapshot/from_snapshot`), снимок поверхности (`AirPlace.surface_start`: классы по карте игры, лесная маска, влажность рельефа) — **данные, которые крейт принимает как вход** (W5 `surface_cls`, `surface_moist`); они зависят от слоёв игры и не относятся к модели погоды. Чтение файлов (`FileAccess`, `Config`, `Locations`), меню (`ui.*`, `sky.options`, румбы), сигналы `weather_changed`/`weather_updated`, подпись экрана загрузки.

## Эталоны

Правило 2026-10-29: эталон снимается, пока жив GD-код; тесты задач — cargo; допуск `1e-6 + 1e-5·|ref|` (W8). Уже есть: `derive` и сырые ячейки `ClimateGrid.at` (6 мест, 220 сочетаний, 6181 строка, `weather_dump`), ход дня `ongudai_day_{1,2,3}`, контекст/вода/поток тепла/профиль ветра (`tests/data/weather_core`), климатические ячейки `RW-12d/climate_cells.json` (2.6 КБ) и `cell` в строках `weather_dump` — только в 6 местах, решётки по миру нет. **Недостаёт** (дыры, закрывает RW-14b до любой правки GD; генераторы — `tools/wind_fixtures/`):

| № | что снять с GD | зачем | набор |
|---|---|---|---|
| E1 | `ClimateGrid.at(lat, lon, month, day)` на решётке | новый код читает и распаковывает сетки сам | решётка 1° × широты −89.5…89.5 шаг 7° × долготы с переходом 180° × 12 месяцев × день 1/15/28; углы: полюса, антимеридиан, ячейки с пропусками −32768, ближайшая ячейка строки, `stub` (`year0 = 0`, `stub_mask`), `none` (нет файла, битый заголовок, неверный размер) — через `set_paths`; все 4 сетки, все ключи и `src` |
| E2 | `ClimateGrid.place` на дне с `valley_msl_m` и `start_msl_m` (рост ветра) | поправки на высоту; сейчас сверено на нескольких ячейках | те же точки × `valley_msl_m ∈ {−100, 0, 500, 3000}`, тропики/умеренные/прочие пояса, оба полушария, сезоны |
| E3 | `SurfaceHeat.air_temp_c`, `water_temp_c` | публичные функции без дампа (воздух — вообще нет в Rust) | 8 мест × 12 месяцев × часы 0…23 × `z ∈ {долина − 200, долина, долина + 1000, 4000}` |
| E4 | `WeatherModel.typical_max_c`, `diurnal_range_k`, `diurnal_state` (+ `sunset_h`, `sunrise_h`) с ctx и без | меню, цель | с `{lat, lon}`, без ctx, ctx без `valley_msl_m`, зажим диапазона |
| E5 | `sky_params`, `haze_k_rh`, `sun_block_cover`, `monthly`, `lerp_table`, `interp_rows`, `reference_context` | мелочи, которых нет в дампе отдельно | таблицы по месяцам/дням (границы 1, 15, 31), все `sky.options`, `t, td` сетка с переходом через 0 |
| E6 | `ground_context` через **`terrain.height_at`** на Онгудае, учебном острове, вулкане и на растре места | дыра риска 2 — расхождение функции и растра 25 м | три места × радиусы (10 км, радиус пасхалки) × число точек (15, 31) × процентили (0.1, 0.25); вывод — разность |
| E7 | `achievement_feed.temp_at_altitude` | живая формула | 6 погод из E-набора × высоты 0…6000 × 4 даты |
| E8 | `goal_estimator.weather_for` (`derive` + `diurnal_state` без рельефа) | цель полёта | 12 `FlightSettings` (места, месяцы, небо) → словарь результата |
| E9 | `AtmoDay.sun_direction` и `hour_at` с зажимом `world.time` | пограничные часы | широты −60…80, месяцы, часы −1…25, `utc_offset_h` NaN/число |
| E10 | `SurfaceHeat.mix_flux`/`land_flux`/`water_flux` по сетке (юнит) + `SurfaceHeating.directions/built_night` по часам | в Rust юнит-тестов потока нет | классы 0…8 × `cos_inc` × `cover` × влажность; часы 0…24 |

Формат: `rust/dp-air/tests/data/RW-14b/*.jsonl.zst` + `manifest.json` (как `weather_dump`), числа `str` с 17 знаками (как `weather_dump.sh`). Генераторы пишутся одним `tools/wind_fixtures/weather_ref2.gd` (+`.sh`) и запускаются headless один раз; E6 — только измерение разницы, жёсткого допуска нет.

## Задачи

Порядок: RW-14b (эталоны) идёт первой и не трогает логику; RW-14c и RW-14d — крейт и мост параллельно после b; RW-14e (потребители) — после d; RW-14f — после e и RW-13; RW-14g — после f; RW-14h — параллельно c…f. Эталоны, а не Godot, проверяют каждую задачу (решение 2026-10-29: тесты задач — cargo). Прогоны Godot и сверка с `main` — в конце модуля.

| ID | что | вход / выход | оценка | приёмка (cargo) |
|---|---|---|---|---|
| RW-14b | снять недостающие эталоны E1…E10 с GD (`tools/wind_fixtures/weather_ref2.*`), положить в `rust/dp-air/tests/data/RW-14b/` | GD жив; файлы + `manifest.json` с опорной ревизией | ≈ 400 строк GD, 1 агент, быстро | скрипт воспроизводится дважды, файлы одинаковы; размер < 5 МБ; список дыр закрыт |
| RW-14c | `dp_air::weather::Weather`: `ClimateGrids::from_bytes` (+ `brotli` в зависимости), `climate_at`, публичные `air_temp_c`, `temp_at_altitude`, `reference_context`, обёртки `typical_max_c/derive/…`; `loc.climate*` убрать из чтения заголовка; `gain_per_km` по умолчанию из климата | эталоны E1…E9; код крейта | ≈ 700 строк Rust + ≈ 500 тестов | `cargo test` E1…E9 в допуске; clippy/fmt; отсутствие сетки ведёт к `fallback` |
| RW-14d | `DpWeather` в `dp-gd`, `DpAir.attach_weather`, `place_context`, контракт W3 v9 / W5 v10 (правка контрактов — координатор) | задача c; `rust/dp-gd/` | ≈ 250 строк Rust + тест моста | `rust/dp-gd/tests/bridge.rs`: вызовы дают те же JSON, что `Weather` напрямую |
| RW-14e | потребители на фасад: `scripts/atmosphere/weather.gd` (тонкая статическая обёртка `Weather` над `DpWeather`, **не** реализация: 1 вызов — 1 метод), перевод `game.gd`, `flight_settings.gd`, `flight_setup_screen.gd`, `goal_estimator.gd`, `achievement_feed.gd`, `egg_place.gd`, комментарий `sky_environment.gd`; конфиг-вырезка `ui.*` остаётся в GD | задачи c, d; ≈ 14 файлов | ≈ 300 строк GD правок | грубая: `godot --headless --check-only` и GD-тесты `test_forecast_game`, `test_goal_estimator`, `test_achievement_feed`, `test_game_logic` (малые, секунды); без полного прогона |
| RW-14f | данные места: убрать `AirPlaceData.fill_climate`/`_climate_cell` и `Terrain`-ветку (`terrain`, `thermal_source_strength_at`, `set_water_heat`, `set_class_sun`, `_update_water_heat`, `SurfaceHeating` в `game.gd`) — если RW-13 ещё не удалил; `AirPlace.Surface` оставить как «снимок поверхности» и вынести в `scripts/terrain/surface_snapshot.gd` | задача e (или RW-13) | ≈ −600 строк GD | `grep` пуст по `fill_climate`, `water_temp_c`; GD-тесты места |
| RW-14g | удалить `weather_model.gd`, `atmo_day.gd`, `surface_heat.gd`, `surface_heating.gd`, `climate_grid.gd`, `.uid`, тесты `test_weather_model/day/surface_heat*`/`test_air_place*` (перенос в cargo сделан), `tools/weather/*` (или перевести на `DpWeather`), `tools/wind_fixtures/*dump*` оставить только как справку; `configs/weather_model.json` вырезка `ui` | задачи e, f, RW-13 | ≈ −2200 строк GD | `grep -rwE 'WeatherModel|AtmoDay|SurfaceHeat|SurfaceHeating|ClimateGrid' scripts tests tools` пуст; `.dpcli/dpcli docs check`; `git grep` по `.gd` пуст |
| RW-14h | порт недостающих GD-тестов в cargo: `test_surface_heat.gd` (9), `test_surface_heating.gd` (2), `test_storm_rarity.gd` (3), HH7 `test_haze_humidity_contracts` часть ClimateGrid (48), `test_air_place_climate_lag` | эталоны b; параллельно | ≈ 500 строк Rust | эквивалентные утверждения проходят |
| RW-14z | проверка чистоты dp-air (скрипт + `cargo test`) и итоговая сверка погоды: таблица «где не уверен» по задачам | всё выше | ≈ 150 строк | см. «Чистота dp-air» |

RW-14e/f/g не должны обгонять RW-13 (`air_place.gd` и GD-решатель держат половину потребителей `WeatherModel`; удалять сначала их — переводимых файлов остаётся ≈ 14 живых вместо ≈ 29 со ссылками). Но RW-14b снимать надо **до** RW-13: дампы `gen_fixtures.gd`/`weather_dump.gd` зовут `AirPlace`, `ClimateGrid`, `Atmosphere` GD-реализации. Если RW-13 выходит раньше — снять эталоны E1…E10 нужно до слияния (иначе источник утрачен).

## Чистота dp-air

Решение 2026-10-30: `dp-air` не знает игры. Что в крейте сейчас (grep по `rust/dp-air/src`), что с этим делать, как проверять.

| находка | где | действие |
|---|---|---|
| путь игры `res://data/locations/<id>/air/<старт>.json` | `field/baked.rs:42, 574` (`BAKED_ROOT`, `path_of`) | убрать: файлы запечённого поля читает GD/dp-gd и отдаёт данными; крейту оставить кодек (`encode_baked/decode`) |
| `.json`-суффиксы имён `configs/*.json` | `place_input.rs:42`, `runtime.rs:237`, `weather_core.rs:189`, `terms/mod.rs:115`, `terms/frame.rs:98`, `phase/config.rs:172` | имена секций нейтральные (`air`, `weather`, `surface_heat`, …), без `.json`; переименование — одним правилом в `Configs::section(name)` (сейчас шесть копий поиска) |
| «старт» как сущность игры | `place.rs` (`StartSite`, `start_sites`), `lib.rs`, `formula.rs`, `runtime.rs` | `StartSite` → «опорная точка места» (`anchor`: id, x, z, h) — это данные, но имя игровое; только переименование |
| «меню» | `window.rs`, `wind_profile.rs`, `case_prepare.rs` (`u10_menu`), `Conditions.inflow_mode` | `u10_ref` — «ветер на 10 м, заданный пользователем (прогноз)»; `inflow_mode` («встречный»/«по меню») — перечисление источника ветра, название нейтральное |
| «запечённые» | `baked.rs`, `types.rs`, `formula.rs`, `runtime.rs`, `field_cache.rs` | «запечённое поле» — понятие кеша расчёта (место → поле); нейтрально называть `precomputed`/`cached_field`; формат TI-К3 — внутренний |
| `compat/*` (FastNoiseLite/PCG32/hash Godot) и ссылки «Godot» в 22 файлах | `compat/`, `terms/thermal*`, `turb/gust.rs`, `storm`, `debug_rasters.rs`, `baked.rs` (`gd_num`, `snappedf`, `angle_difference`) | решение после RW-13 (решение пользователя): оставить как обычный шум/ГСЧ без слова Godot (`noise`, `rng`) — совместимость со старым не нужна; `gd_num` (форматирование чисел как `str(float)` Godot) уйдёт с запечёнными файлами |
| `fixtures.rs` (пути `tests/fixtures/wind`, `places/*.json`) | `fixtures.rs:24, 260, 449` | перенести в `tests/common/` или под `cfg(feature = "fixtures")`; в публичный API не входит |
| виды понятия «игра» (бот, камера, UI, достижения, сеть) | `grep -ri 'камер\|achiev\|достижен'` — 0; «bot» — совпадения только в слове *bottom* | чисто |
| `Source` (`conditions.rs`) — «эталон/прогноз» | `conditions.rs:20` | оставить: вид входа (готовая погода или прогноз) |

**Проверка (RW-14z):** (1) `cargo tree -p dp-air` — нет `godot*`, `gdext*`; (2) `grep -rniE 'res://|user://|data/locations|configs/|\.json"|godot|menu|меню|достиж|камер' rust/dp-air/src` → пусто, кроме явного белого списка (`serde_json` — это библиотека; текстовый формат входа `Configs`, не путь); (3) тест `rust/dp-air/tests/purity.rs`: читает `src/**/*.rs`, ищет запрещённые подстроки (список — константа теста), падает с файлом и строкой; (4) в публичном API (`cargo doc` либо `cargo public-api`) нет типов из `dp-gd`.

## Риски и «где не уверен»

1. **brotli:** `brotli 3.5` лежит в `~/.cargo/registry`, но его нет в `rust/Cargo.lock` — добавление зависимости требует офлайн-сборки; проверить `cargo build --offline`. Запасной путь: распаковывать в GD (`PackedByteArray.decompress`) и отдавать крейту уже `raw` — тогда код `from_bytes` принимает `raw` и заголовок отдельно, крейт файл-формат HH не знает (чище). Выбор — координатору (по умолчанию: распаковка в GD, чтобы не тянуть зависимость).
2. **`ground_context`: функция рельефа против растра 25 м.** `Game._weather_context` считает долину и среднюю высоту по `terrain.height_at` (непрерывная функция, 15 × 15 точек в круге 10 км, процентиль 0.1); крейт — по растру `Place`. Расхождение даёт сдвиг `valley_msl_m` → `derive` (высота термиков, кромка). Не измерено; E6 снимает цифру. Если сдвиг > 5 м — вариант: GD считает долину и отдаёт числом в заголовке места (в заголовке W5 `valley_msl_m` сейчас нет — `place.rs`, `Loc`; нужно поле), крейт принимает.
3. **Дискретизация хода дня** (0,1 с / 1 с / 60 с, RW-8a) и разделение `weather_model.json` на физику и меню — как есть; правка `configs/` вне скоупа RW-14a.
4. **Обёртка `Weather`** (риск «вторая реализация»): альтернатива — вызывать `DpWeather` напрямую (≈ 40 вызовов в 14 файлах); рекомендую обёртку «вызов — метод».
5. **`reference_context`/`noon_elevation_deg`** — прямого аналога в крейте не нашёл; сверить в RW-14c.
6. Оценки строк — по размеру GD и RW-12 (900 Rust на 735 GD).
