//! Погода из прогноза (RW-12b): перенос `WeatherModel.derive` и `ClimateGrid.place` без Godot.
//!
//! Чистые функции над f64 (GDScript `float`), без состояния. Эталон — дамп GD
//! (`tools/wind_fixtures/weather_dump.sh`), тест — `tests/weather_derive.rs`.
//! Ход дня (RW-12c): [`AtmoDay`] (часы места, погода по квантам, солнце, источник), [`Coefficients`]
//! (`_cache_coefficients`), [`WeatherState`] (мягкая смена, ход дня по шагам, номера версий, `sun_state`).
//!
//! - [`climate_place`]: сырая ячейка климата (`ClimateGrid.at`, W5 v8) + контекст места →
//!   [`ClimatePlace`] (поправки на высоту долины и рост ветра; `ClimateGrid.place`).
//! - [`derive`]: прогноз + место + час → словарь погоды с `_derived` (ключи как у GD).
//! - [`td_day`], [`td_noise`], [`haze_k_rh`], [`cirrus_base_cover`], [`sun_block_cover`],
//!   [`lerp_table`], [`interp_rows`] — части `derive`.
mod climate;
mod coeffs;
mod day;
mod derive;
mod noise;
mod state;
mod tables;

pub use climate::{ClimatePlace, ClimateSrc, PlaceCtx, climate_place};
pub use coeffs::{Coefficients, wind_conditions};
pub use day::{
    AtmoDay, SourceFn, SunSpec, WeatherFn, WeatherMap, WorldTime, forecast_weather_fn,
    sun_direction,
};
pub use derive::{cirrus_base_cover, derive, haze_k_rh, sun_block_cover};
pub use noise::{splitmix64, td_day, td_noise};
pub use state::WeatherState;
pub use tables::{interp_rows, lerp_table};
