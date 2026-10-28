//! Погода из прогноза (RW-12b): перенос `WeatherModel.derive` и `ClimateGrid.place` без Godot.
//!
//! Чистые функции над f64 (GDScript `float`), без состояния. Эталон — дамп GD
//! (`tools/wind_fixtures/weather_dump.sh`), тест — `tests/weather_derive.rs`.
//! Не здесь (RW-12c): `AtmoDay`, коэффициенты суммы, мягкая смена, версии погоды.
//!
//! - [`climate_place`]: сырая ячейка климата (`ClimateGrid.at`, W5 v8) + контекст места →
//!   [`ClimatePlace`] (поправки на высоту долины и рост ветра; `ClimateGrid.place`).
//! - [`derive`]: прогноз + место + час → словарь погоды с `_derived` (ключи как у GD).
//! - [`td_day`], [`td_noise`], [`haze_k_rh`], [`cirrus_base_cover`], [`sun_block_cover`],
//!   [`lerp_table`], [`interp_rows`] — части `derive`.
mod climate;
mod derive;
mod noise;
mod tables;

pub use climate::{ClimatePlace, ClimateSrc, PlaceCtx, climate_place};
pub use derive::{cirrus_base_cover, derive, haze_k_rh, sun_block_cover};
pub use noise::{splitmix64, td_day, td_noise};
pub use tables::{interp_rows, lerp_table};
