---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "RW-14e: обёртка Weather над DpWeather, перевод потребителей погоды, список удалённого GDScript, границы и сомнения."
conclusion: "Погода считается один раз — в dp-air. В GDScript остался Weather (вызов DpWeather + чтение конфигов и сеток ERA5), SurfaceSnapshot (снимок поверхности рельефа игры для load_place) и меню (Weather.config ui/sky). Удалены weather_model, atmo_day, surface_heat, surface_heating, climate_grid, air_model/air_place и тесты, зависевшие от них; поток тепла по классам и усиление у границ классов Terrain больше не знает."
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3/rw14-weather.md", "docs/contracts/rust-wind/weather.md", "docs/contracts/rust-wind.md"]
---

# RW-14e: потребители погоды на DpWeather, удаление погоды на GDScript

Основание: решение пользователя 2026-10-30 (одна реализация погоды — в крейте), проект `rw14-weather.md`, контракт W12 v3.

## Что появилось

| файл | что |
|---|---|
| `scripts/atmosphere/weather.gd` (`Weather`) | статические методы над `DpWeather`: `typical_max_c`, `diurnal_state`, `sunrise_h/sunset_h`, `sky_params`, `derive`, `air_temp_c`, `water_temp_c`, `temp_at_altitude`, `climate_cell`, `reference_context`, `quantum_h`, `hour_at`, `valley_of`, `ground_context`; `config()` — секция `weather_model` для меню (`ui.*`, `sky.options`, `valley_percentile`). Читает конфиги (`config_text`/`config_pairs` — их же берёт `Atmosphere._dp_configs`) и сетки ERA5 (`data/climate/*.bin`: заголовок 64 Б + тело, распакованное brotli). Один `DpWeather` на игру, создаётся лениво; `DpAir.attach_weather` в `Atmosphere._dp_start` передаёт тот же `Arc`. `set_grid_paths` — подмена файлов сеток (тесты). |
| `scripts/atmosphere/surface_snapshot.gd` (`SurfaceSnapshot`) | снимок поверхности места (`AirPlace.Surface`, `surface_start/of`, `_surface_fill`), без сеток области решателя (`cells/precompute/domain_dx` — только GD-решатель). Остался в GD: классы и влажность берутся из карт рельефа игры. |

Отображение ключей: `diurnal_state` отдаёт `break` (в крейте `brk`) и `cap_agl_m = INF` (в JSON `null`); `derive` — `_derived.cap_agl_m = INF`. `sky_params` — `{cover, sky_heat}` (остальные ключи секции `sky` — `Weather.config().sky.<имя>`).

## Потребители

| файл | было | стало |
|---|---|---|
| `game.gd` | `AtmoDay` (часы), `SurfaceHeating`, `ClimateGrid.place` (`gain_per_km`), `AirPlaceData.fill_climate`, `SurfaceHeat.water/air_temp_c`, контекст воды Terrain | свои поля `_day_*` + `Weather.hour_at`, `Weather.quantum_h`, `wind_ref` без `gain_per_km` (берёт крейт, W5 v10), `Weather.ground_context/air_temp_c/sky_params`; вода и классовое солнце Terrain удалены |
| `flight_settings.gd`, `flight_setup_screen.gd` | `WeatherModel.typical_max_c/config` | `Weather.typical_max_c(месяц, день, lat, lon)`, `Weather.config` |
| `start_weather.gd`, `sky_environment.gd` | `WeatherModel.config` / комментарий | `Weather.config` |
| `goal_estimator.gd` | `derive`, `diurnal_state`, `reference_context` | `Weather.*` |
| `achievement_feed.gd` | формула профиля температуры в GD | `Weather.temp_at_altitude` |
| `egg_place.gd`, `atmo_fingerprint.gd` | `WeatherModel.ground_context`, `AtmoDay.sun_direction` | `Weather.ground_context`; солнце — `SunClock` + `TerrainGeo` |
| `atmosphere.gd` | `fill_climate`, `AirPlace.Surface`, свой разбор конфигов | `Weather.config_pairs`, `attach_weather`, `SurfaceSnapshot`; `wind_ref.gain_per_km` необязателен |
| `air_place_data.gd` | `fill_climate`, `source_at`, `SUN_FOR_SOURCE` | удалены (W5 v10: климат считает крейт) |
| `terrain.gd` | `thermal_source_strength_*`, `set_water_heat`, `set_class_sun`, `_edge_proximity`, `SurfaceHeat`-конфиг | удалены (мёртвый путь GD-реализации; поток тепла и усиление у границ — крейт) |

## Удалено

`scripts/atmosphere/{weather_model,atmo_day,surface_heat,surface_heating,climate_grid}.gd`, `air_model/air_place.gd`; тесты `test_surface_heat`, `test_surface_heating`, `test_air_place`, `test_air_square`, `test_surface_heat_contracts`, `test_air_place_climate_lag`; генераторы эталонов `tools/wind_fixtures/weather_dump.*`, `weather_ref2.*`, `rust/dp-air/tests/data/RW-10c/dump_source.*` (требовали удалённый GD-код; снятые ими файлы эталонов остаются).

Портированы под `Weather`: `test_weather_model` (поведение дня: монотонность, ход дня, небо), `test_haze_humidity_contracts` (раздел HH7 — `climate_cell`), `test_haze_humidity_hh3`, `test_feedback_1013_contracts` (погода и рождения; поток тепла по классам — в cargo), тесты игры/целей/достижений.

## Границы и сомнения

- Сверка поведения Godot-тестами сократилась: проверки `SurfaceHeat.mix_flux` по классам (вечер, вода, застройка), порядка силы источника по классам и усиления у границ классов теперь только в cargo; юнит-тестов `field/surface_heat.rs` нет (проект RW-14h должен их портировать). Это потеря покрытия на стороне Godot до RW-14h.
- `Weather.ground_context` считает среднюю высоту суммой в GD (арифметика проб рельефа), долину — крейт (`valley_of`); пробы берёт игра.
- `tools/research/**` (дампы на удалённых классах) не правились (`dont_touch`).

## Где зовётся attach_weather и почему пресету он не нужен

`DpAir.attach_weather(Weather.dp())` вызывает `Atmosphere._dp_start` — один раз на `configure` (новая модель в крейте обнуляет привязку, поэтому `_dp_weather` сбрасывается вместе с подписью конфигов) и до `load_place` (W3 v9). Повторный `attach` перестраивает уже заданные условия, и `weather()` до следующего `set_conditions` пуст, потому вызов под защитой `_dp_weather != wx`. Звать его нужно только для прогноза (`_dp_field_wanted()`): климат места, ход дня и `derive` по часу крейт берёт у `Weather` лишь в `Source::Forecast`. Эталон-пресет (превью, тесты) берёт словарь пресета как есть (`Source::Preset`), климат места ему не нужен; без `attach` крейт держит запасной климат `climate.fallback` (физика пресета-эталона не выводится по часу, потому смысл не меняется).
