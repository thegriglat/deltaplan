//! Слагаемое `wave` и σ ротора (RW-11b): подветренные волны в слоте `Extra`, гребни W6.
//!
//! Входы: рамка ветра (`Terms::wind`: скорость на `wave.wind_reference_agl_m` и направление),
//! погода (`wave_strength`, `stability_n_per_s` из `WeatherView`), рельеф места (`Ctx::place`).
//! Поле [`WaveField`] пересобирается, когда меняются сила, N, λ (> 1 м), направление (> 1e-3),
//! конфиги или место (как `set_wind`/`setup` в GD). Гребни — [`wave_crests`] (подключение к
//! трейту `AirModel` — RW-12z).
mod field;

use super::slots::{Extra, ExtraOut};
use super::{Ctx, Terms};
use crate::Configs;
use crate::Crest;
use crate::Place;
use crate::field::runtime::ground_height;
pub use field::{Ground, WaveCfg, WaveField, dir_f32};
use std::sync::{Arc, Mutex};

/// Что делает кеш недействительным помимо ветра: конфиги, сила/N погоды, место.
#[derive(Clone, PartialEq)]
struct Key {
    strength: u64,
    n_bv: u64,
    place: (usize, usize),
}

struct Cached {
    configs: Arc<Configs>,
    cfg: WaveCfg,
    key: Key,
    field: Arc<WaveField>,
}

/// Слот волн: состояние — производный кеш поля (чистый, пересобирается по входам).
#[derive(Default)]
pub struct WaveExtra {
    cache: Mutex<Option<Cached>>,
}

fn place_id(p: &Place) -> (usize, usize) {
    (p.heights().as_ptr() as usize, p.heights().len())
}

impl WaveExtra {
    pub fn new() -> Self {
        Self::default()
    }

    /// Поле для текущих погоды, ветра и места; `None` — волн нет (`wave_strength ≤ 0`).
    pub fn field(&self, terms: &Terms, place: &Place) -> Option<(Arc<WaveField>, WaveCfg)> {
        let strength = terms.weather.f64_or("wave_strength", 0.0);
        if strength <= 0.0 {
            return None; // быстрый путь: без волны конфиг не разбираем
        }
        let mut g = self.cache.lock().unwrap();
        let reuse_cfg = g
            .as_ref()
            .is_some_and(|c| Arc::ptr_eq(&c.configs, &terms.configs));
        let cfg = if reuse_cfg {
            g.as_ref().unwrap().cfg.clone()
        } else {
            WaveCfg::from_configs(&terms.configs)
        };
        let n_bv = terms
            .weather
            .f64_or("stability_n_per_s", cfg.default_n_per_s);
        let speed = terms.wind.speed_at(cfg.wind_reference_agl_m);
        let fresh = WaveField::new(&cfg, strength, n_bv, speed, terms.wind.dir());
        let key = Key {
            strength: strength.to_bits(),
            n_bv: n_bv.to_bits(),
            place: place_id(place),
        };
        if let Some(c) = g.as_ref()
            && reuse_cfg
            && c.key == key
            && c.field.same_wind(&fresh)
        {
            return Some((c.field.clone(), cfg));
        }
        let field = Arc::new(fresh);
        *g = Some(Cached {
            configs: terms.configs.clone(),
            cfg: cfg.clone(),
            key,
            field: field.clone(),
        });
        Some((field, cfg))
    }
}

impl Extra for WaveExtra {
    fn flow(&self, c: &Ctx, _v: [f64; 3]) -> Option<ExtraOut> {
        let (f, cfg) = self.field(c.terms, c.place)?;
        let u = c.terms.wind.speed_at(cfg.wind_reference_agl_m);
        let gh = |x: f64, z: f64| f64::from(ground_height(c.place, x as f32, z as f32));
        let (w, rotor) = f.sample(
            f64::from(c.pos[0]),
            f64::from(c.pos[1]),
            f64::from(c.pos[2]),
            c.agl,
            u,
            &gh,
        );
        Some(ExtraOut {
            wave: [0.0, w, 0.0],
            sigma_rotor: rotor,
            ..ExtraOut::default()
        })
    }

    fn crests(
        &self,
        terms: &Terms,
        place: &Place,
        center: [f32; 2],
        radius: f32,
        min_eta: f32,
        spacing: f32,
        out: &mut Vec<Crest>,
    ) {
        out.clear();
        let Some((f, _)) = self.field(terms, place) else {
            return;
        };
        let gh = |x: f64, z: f64| f64::from(ground_height(place, x as f32, z as f32));
        *out = f.crests(center, radius, min_eta, spacing, &gh);
    }
}

/// Гребни волн W6 (`wave_crests`): `[x, z, eta, crest]` (`CREST_STRIDE = 4`), сильные первыми;
/// волн или места нет — пусто.
pub fn wave_crests(
    terms: &Terms,
    place: Option<&Place>,
    center: [f32; 2],
    radius: f32,
    min_eta: f32,
    spacing: f32,
    out: &mut Vec<Crest>,
) {
    out.clear();
    if let Some(p) = place {
        terms
            .slots
            .extra
            .crests(terms, p, center, radius, min_eta, spacing, out);
    }
}
