//! Граница ветра (W4): трейт `AirModel`, типы входа и выхода, разбор входа (W5), заглушка `Calm`.
//!
//! Крейт не зависит от Godot. Реализации: `Calm` (здесь), `Formula` (RW-6…12), `Live` (вне модуля).

mod calm;
pub mod compat;
mod conditions;
mod error;
pub mod field;
pub mod fixtures;
mod formula;
mod level;
mod place;
pub mod terms;
mod types;
pub mod weather;

pub use calm::Calm;
pub use conditions::{Conditions, Forecast, InflowMode, Source, WindRef};
pub use error::{Code, Error};
pub use formula::Formula;
pub use level::{
    Level, NestDst, NestSrc, Shift, ShiftDst, ShiftSrc, Stag, nest, prolong, prolong_state,
    shift_between, shift_warm,
};
pub use place::{Grid, Loc, LocClimate, Place, PlaceHeader, StartSite};
pub use types::{
    Cloud, Configs, Core, Crest, Decomposition, F32Record, FieldExport, Focus, Raster, SampleMode,
    State, Status, as_f32s,
};

/// Версия границы; равна версии в заголовке W2 `docs/contracts/rust-wind.md`.
pub const API_VERSION: u32 = 3;

/// Модель воздуха. Команды (`&mut self`) — из одного потока; опросы (`&self`) — из любого потока
/// одновременно. Опросы не падают: длины `out` и `pts` обрабатываются по `min`, остальное не
/// трогается; числа на выходе всегда конечны (NaN/inf во входной точке → `(0, 0, 0, 0)`).
pub trait AirModel: Send + Sync {
    fn configure(&mut self, cfg: &Configs, seed: u64) -> Result<(), Error>;
    /// Возвращает сразу; подготовка места — фон.
    fn load_place(&mut self, place: Place) -> Result<(), Error>;
    fn unload_place(&mut self);
    fn set_conditions(&mut self, c: &Conditions) -> Result<(), Error>;
    fn set_sun_direction(&mut self, to_sun: Option<[f32; 3]>);
    fn set_static_thermals(&mut self, list: &[[f32; 4]], mode: u8) -> Result<(), Error>;
    fn set_focuses(&mut self, f: &[Focus]) -> Result<(), Error>;
    fn advance_to(&mut self, t: f64) -> Result<(), Error>;
    fn start_at(&mut self, t: f64) -> Result<(), Error>;
    /// W4 v3: запечённое поле места (W5 v4, TI-К3 v3) сразу после `load_place`, до READY. Реализация
    /// по умолчанию ничего не делает (`Calm`). Неразборчивый заголовок, поле после READY — `BadInput`,
    /// нет места — `NoPlace`.
    fn add_baked_field(&mut self, _header_json: &str, _data: &[u8]) -> Result<(), Error> {
        Ok(())
    }
    /// W4 v3: каталог кеша полей реализации (абсолютный путь); пусто — без кеша. По умолчанию — ничего.
    fn set_cache_dir(&mut self, _path: &str) -> Result<(), Error> {
        Ok(())
    }
    /// W4 v5: режим поля. `false` — поле снимается сразу, расчётов нет, `Loading` из-за поля →
    /// `Ready`; `true` — поле возвращается фоном (запечённое, кеш, расчёт), `state` не меняется.
    /// Повтор значения — `Ok`, ничего. По умолчанию — ничего (`Calm`).
    fn set_field_enabled(&mut self, _on: bool) -> Result<(), Error> {
        Ok(())
    }
    /// W4 v5, переходное (W3 v4): снимок последней подачи поля — целевой набор уровней в формате
    /// TI-К3 v3 без потерь. `version = 0` — поля не было. По умолчанию — пустой.
    fn field_export(&self) -> FieldExport {
        FieldExport::default()
    }
    /// W4 v5: номер последней подачи без кодирования (`0` — подач не было).
    fn field_version(&self) -> u64 {
        0
    }
    fn status(&self) -> Status;
    fn sample_many(&self, pts: &[[f32; 3]], mode: SampleMode, out: &mut [[f32; 4]]);
    fn cloud_density_many(&self, pts: &[[f32; 3]], out: &mut [f32]);
    fn cloudbase_msl(&self) -> f32;
    fn background_wind(&self, heights: &[f32], out: &mut [[f32; 2]]);
    fn weather_json(&self) -> String;
    /// (мягкая версия, версия перестройки)
    fn weather_version(&self) -> (u64, u64);
    fn sun_state(&self) -> [f32; 4];
    fn cores(&self, center: [f32; 3], radius: f32, out: &mut Vec<Core>);
    fn clouds(&self, center: [f32; 3], radius: f32, out: &mut Vec<Cloud>);
    fn cloud_raster(&self) -> Option<std::sync::Arc<Raster>>;
    fn wave_crests(
        &self,
        center: [f32; 2],
        radius: f32,
        min_eta: f32,
        spacing: f32,
        out: &mut Vec<Crest>,
    );
    fn decompose(&self, p: [f32; 3]) -> Decomposition;
    fn debug_raster(&self, name: &str) -> Option<std::sync::Arc<Raster>>;
    fn debug_raster_names(&self) -> Vec<String>;
}
