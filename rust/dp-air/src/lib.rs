//! Граница ветра (W4): трейт `AirModel`, типы входа и выхода, разбор входа (W5), заглушка `Calm`.
//!
//! Крейт не зависит от движка. Реализации: `Calm` (здесь), `Formula` (RW-6…12), `Live` (вне модуля).

mod calm;
mod conditions;
pub mod debug_rasters;
mod error;
pub mod field;
/// Читалка фикстур тестов и стенда (раскладка каталогов фикстур — не часть библиотеки).
#[cfg(feature = "fixtures")]
#[path = "../tests/support/fixtures.rs"]
pub mod fixtures;
mod formula;
pub mod hash;
mod level;
pub mod noise;
mod place;
pub mod rand;
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
pub use place::{Grid, Loc, Place, PlaceHeader, StartSite};
pub use types::{
    Cloud, Configs, Core, Crest, Decomposition, F32Record, FieldExport, Focus, Raster, SampleMode,
    State, Status, as_f32s,
};

/// Версия границы; равна версии в заголовке W2 `docs/contracts/rust-wind.md`.
pub const API_VERSION: u32 = 6;

/// Число полей записи объекта-облака (`OBJ_STRIDE`, W6 v4).
pub const OBJ_STRIDE: usize = 22;

/// Запись объекта-облака (W4 v6: `#[repr(C)]`, 22 `f32`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ObjRecord {
    /// `0` `id & 0xFFFFFF`, уникален в наборе.
    pub id: f32,
    /// `1` бит 0 - статичное, бит 2 - Cb.
    pub flags: f32,
    /// `2, 3` центр основания на `t`, м.
    pub cx: f32,
    pub cz: f32,
    /// `4` основание, м MSL.
    pub base_msl: f32,
    /// `5, 6, 7` рост, распад, активность 0..1 (`CloudModel.stage`).
    pub growth: f32,
    pub decay: f32,
    pub activity: f32,
    /// `8, 9` полуоси по ветру и поперёк, м (`CloudModel.size`).
    pub rx: f32,
    pub rz: f32,
    /// `10, 11` мощность и растекание верха, м.
    pub depth: f32,
    pub spread: f32,
    /// `12` `noise_seed mod 9973`.
    pub vis_seed: f32,
    /// `13, 14` появление и конец облака, с атмосферы (статичное - `∓1e30`).
    pub life_t0: f32,
    pub life_t1: f32,
    /// `15, 16` источник на земле, м.
    pub src_x: f32,
    pub src_z: f32,
    /// `17, 18` скорость сноса, м/с (статичное - 0).
    pub drift_vx: f32,
    pub drift_vz: f32,
    /// `19` начало сноса, с (статичное - `+1e30`).
    pub drift_t0: f32,
    /// `20` начало грозы, с (не Cb - 0).
    pub storm_t0: f32,
    /// `21` интенсивность грозы на `t`, 0..1 (не Cb - 0).
    pub storm_k: f32,
}

const _: () = assert!(std::mem::size_of::<ObjRecord>() == OBJ_STRIDE * 4);

// SAFETY: `#[repr(C)]`, одни `f32`, размер проверен const-assert выше.
unsafe impl F32Record for ObjRecord {}

impl ObjRecord {
    /// Плоский вид (порядок полей W6 v4).
    pub fn to_array(&self) -> [f32; OBJ_STRIDE] {
        [
            self.id,
            self.flags,
            self.cx,
            self.cz,
            self.base_msl,
            self.growth,
            self.decay,
            self.activity,
            self.rx,
            self.rz,
            self.depth,
            self.spread,
            self.vis_seed,
            self.life_t0,
            self.life_t1,
            self.src_x,
            self.src_z,
            self.drift_vx,
            self.drift_vz,
            self.drift_t0,
            self.storm_t0,
            self.storm_k,
        ]
    }
}

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
    /// W4 v3: каталог кеша полей реализации (абсолютный путь); пусто — без кеша. По умолчанию — ничего.
    fn set_cache_dir(&mut self, _path: &str) -> Result<(), Error> {
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
    /// W4 v10: погода с сетками климата (общая `Arc`, W12); до `load_place`. Климат места
    /// (W5 v10) берётся у неё; не задана - запасные значения конфига. По умолчанию - ничего.
    fn set_weather(&mut self, _w: std::sync::Arc<weather::Weather>) {}
    /// W4 v10: контекст загруженного места (дата, положение, пояс, высоты долины и средней);
    /// нет места - `None`. По умолчанию `None`.
    fn place_context(&self) -> Option<weather::PlaceContext> {
        None
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
    /// W4 v6: объекты-облака W6 v4 на момент `t` (вне окна истории — ближайшая граница). По
    /// умолчанию пусто (`Calm`).
    fn cloud_objects(&self, _center: [f32; 3], _radius: f32, _t: f64, out: &mut Vec<ObjRecord>) {
        out.clear();
    }
    /// W4 v6: `[enabled, wavelength_m]`; по умолчанию нули.
    fn wave_info(&self) -> [f32; 2] {
        [0.0; 2]
    }
    /// W4 v6: порыв у поверхности в точках `xz` на моменты `t`; по умолчанию нули.
    fn surface_gust_many(&self, _xz: &[[f32; 2]], _t: &[f64], out: &mut [f32]) {
        out.iter_mut().for_each(|o| *o = 0.0);
    }
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
