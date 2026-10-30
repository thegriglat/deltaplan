//! Слагаемое `storm` (RW-11c): гроза термиков-Cb (`StormField`) и физика облака Cb
//! (`CloudModel.stage/size/center/_life_window`).
//!
//! - [`StormField`] - нисходящий поток ливня, растекание, фронт порывов и σ; чистая функция
//!   набора термиков и времени. [`StormExtra`] - часть слота `Extra`: берёт ячейки (`is_cb`) из
//!   снимка слота термиков (`thermal::ThermalSlot::state`), как `StormField.refresh` в эталоне
//!   берёт их при каждом обновлении набора.
//! - [`CloudModel`] - стадия, окно жизни, центр и размеры облака Cb; нужны описаниям W6 и
//!   подсосу (RW-11d). Рисование (выбор, затухание по дальности, слияние) - у потребителя.
//! - Радиус ливня `rd = clouds.width_per_ms_m · cloud_size_factor · сила · 0,5 · downdraft_radius_frac`;
//!   `cloud_size_factor` читается из погоды при каждом опросе (в эталоне `StormField.setup` берёт
//!   его один раз при сборке атмосферы; при мягком обновлении погоды ходом дня он не менялся).
//!
//! Границы модели: потоки ячеек не складываются выше одной (горизонталь ≤ `outflow_ms`,
//! вертикаль ∈ [−`downdraft_ms`, `front_updraft_ms`]); σ - наибольшая из ячеек; ветер фона
//! (профиль) на грозу не влияет.
mod cloud_model;
mod field;

pub use cloud_model::{CloudCfg, CloudModel, NO_CLOUD, Stage};
pub use field::{StormCfg, StormField, StormSample, cloud_center};

use super::slots::{Extra, ExtraOut};
use super::thermal::AtmoThermal;
use super::{Ctx, Terms};
use crate::Configs;
use std::sync::{Arc, Mutex};

/// Ячейки грозы набора термиков слота `terms` (пусто, если набора нет).
pub fn cells(terms: &Terms) -> impl Iterator<Item = &AtmoThermal> {
    terms
        .slots
        .thermal
        .as_slot()
        .and_then(|s| s.state())
        .into_iter()
        .flat_map(|st| st.all.iter())
        .map(|a| &**a)
        .filter(|th| th.is_cb)
}

/// `StormField` для текущих конфигов и погоды `terms`.
pub fn field_of(terms: &Terms, cfg: StormCfg) -> StormField {
    StormField::new(cfg, terms.weather.f64_or("cloud_size_factor", 1.0))
}

/// Интенсивность грозы ядра 0..1 в момент `t` (поле `storm` ядра W6); не Cb - 0.
pub fn core_intensity(terms: &Terms, th: &AtmoThermal, t: f64) -> f64 {
    if !th.is_cb {
        return 0.0;
    }
    field_of(terms, StormCfg::from_configs(&terms.configs)).intensity(th, t)
}

/// Часть слота `Extra`: слагаемое `storm` и σ грозы.
#[derive(Default)]
pub struct StormExtra {
    /// Разобранный конфиг и адрес `Configs`, из которых он взят.
    cache: Mutex<Option<(usize, StormCfg)>>,
}

impl StormExtra {
    pub fn new() -> Self {
        Self::default()
    }

    fn cfg(&self, configs: &Arc<Configs>) -> StormCfg {
        let ptr = Arc::as_ptr(configs) as usize;
        let mut g = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        match *g {
            Some((p, c)) if p == ptr => c,
            _ => {
                let c = StormCfg::from_configs(configs);
                *g = Some((ptr, c));
                c
            }
        }
    }
}

impl Extra for StormExtra {
    fn flow(&self, c: &Ctx, _v: [f64; 3]) -> Option<ExtraOut> {
        let mut it = cells(c.terms).peekable();
        it.peek()?;
        let f = field_of(c.terms, self.cfg(&c.terms.configs));
        let s = f.sample(it, c.pos, c.agl, c.t);
        // `Vector4` эталона - f32
        let q = |x: f64| f64::from(x as f32);
        Some(ExtraOut {
            storm: [q(s[0]), q(s[1]), q(s[2])],
            sigma_storm: q(s[3]),
            ..ExtraOut::default()
        })
    }
}
