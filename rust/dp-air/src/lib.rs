//! Граница ветра (W4): трейт `AirModel`, типы входа и выхода, разбор входа (W5), заглушка `Calm`.
//!
//! Крейт не зависит от Godot. Реализации: `Calm` (здесь), `Formula` (RW-6…12), `Live` (вне модуля).

mod calm;
mod conditions;
mod error;
pub mod field;
pub mod fixtures;
mod level;
mod place;
mod types;

pub use calm::Calm;
pub use conditions::{Conditions, Forecast, Source, WindRef};
pub use error::{Code, Error};
pub use level::{Level, Stag, prolong, prolong_state};
pub use place::{Grid, Loc, Place, PlaceHeader, StartSite};
pub use types::{
    Cloud, Configs, Core, Crest, Decomposition, Focus, Raster, SampleMode, State, Status,
};

/// Версия границы; равна версии в заголовке W2 `docs/contracts/rust-wind.md`.
pub const API_VERSION: u32 = 1;

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
