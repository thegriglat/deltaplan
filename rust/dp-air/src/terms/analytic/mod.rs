//! Слот `Analytic` (RW-9): аналитика ветра без поля и в полосе края поля `a < 1`, склоновый
//! подъём, подветренная зона, фоновый ветер. Перенос из `atmosphere.gd`
//! (`air_velocity_at` 921–988, `_air_velocity_field` 1075–1131, `_analytic_amp` 1031,
//! `_analytic_turb` 1047), `ground_field.gd`, `wind_model.gd`.
//!
//! - `ground` — `GroundField`: склон, линия тени, превышение гребня (кеш кусков 30 м).
//! - `ridge` — склоновый подъём; `lee` — подветренная зона (опускание, рывки, ротор, опасность);
//!   `strip` — доля аналитики в полосе края поля.
//! - `noise` — `gust_unit` (шум пятен рывков и пульсаций аналитики).
//!
//! Слот создаётся незаданным (`AnalyticSlot::unconfigured`, всё `None`) и становится рабочим в
//! `Terms::configure` через `Analytic::configured` (конфиги и сид). Состояния во времени нет:
//! все вклады — функция `(точка, t)`; кеш кусков рельефа — на пару «место, направление ветра».
//!
//! Допущения (в отчёте задачи): высота — билинейно по растру места, а не `terrain.height_at`
//! (риск 1); облачная кромка для конвективной доли — `ground_ref + cloudbase_agl_m` погоды
//! (мягкая подмена кромки — RW-12); ход профиля по часу (`set_conditions` ветра) — RW-12.
pub mod ground;
pub mod lee;
pub mod noise;
pub mod ridge;
mod strip;

use self::ground::{GroundCfg, GroundField, GroundSample, PlaceSig};
use self::lee::LeeCfg;
use self::noise::{GustNoise, NoiseCfg};
use self::ridge::RidgeCfg;
use super::{Analytic, AnalyticMean, AnalyticTurb, Ctx, Terms, ThermalOut, named_json};
use crate::Configs;
use crate::place::Place;
use serde_json::Value;
use std::sync::{Arc, RwLock};

/// Профиль Ленчова `σ_w ∝ √(1,8 ξ^(2/3) (1 − 0,8 ξ)²)`.
pub fn lenschow(xi: f64) -> f64 {
    let a = 1.0 - 0.8 * xi;
    (1.8 * xi.powf(2.0 / 3.0) * a * a).sqrt()
}

/// Все настройки аналитики из `atmosphere.json`.
#[derive(Clone, Debug, PartialEq)]
pub struct AnalyticCfg {
    pub ground: GroundCfg,
    pub ridge: RidgeCfg,
    pub lee: LeeCfg,
    pub noise: NoiseCfg,
    /// `turbulence.mech_per_wind`, `mech_ground_boost`, `mech_ground_height_m`.
    pub mech_k: f64,
    pub mech_boost: f64,
    pub mech_h: f64,
    /// `turbulence.vertical_ratio`, `advection_height_m`.
    pub vert_ratio: f64,
    pub advect_h: f64,
}

impl AnalyticCfg {
    pub fn from_configs(c: &Configs) -> Self {
        let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);
        let g = |p: &str, d: f64| atm.pointer(p).and_then(Value::as_f64).unwrap_or(d);
        let gd = GroundCfg::default();
        let dists: Vec<f64> = atm
            .pointer("/lee/upwind_distances_m")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_f64).collect())
            .filter(|v: &Vec<f64>| !v.is_empty())
            .unwrap_or(gd.dists.clone());
        let ground = GroundCfg {
            cell: g("/ground/cell_m", gd.cell).max(1.0e-3),
            chunk_cells: (g("/ground/chunk_cells", gd.chunk_cells as f64) as usize).max(1),
            max_chunks: (g("/ground/max_chunks", gd.max_chunks as f64) as usize).max(1),
            dists,
            tan_shadow: g("/lee/shadow_angle_deg", 12.0).to_radians().tan(),
            ref_radius: g("/ground/reference_radius_m", gd.ref_radius),
            ref_samples: g("/ground/reference_samples", gd.ref_samples as f64) as usize,
        };
        let rd = RidgeCfg::default();
        let ridge = RidgeCfg {
            eff: g("/ridge/efficiency", rd.eff),
            decay: g("/ridge/decay_height_m", rd.decay),
            shift_k: g("/ridge/forward_shift_factor", rd.shift_k),
            shift_max: g("/ridge/forward_shift_max_m", rd.shift_max),
            max: g("/ridge/max_lift_ms", rd.max),
        };
        let nd = NoiseCfg::default();
        let noise = NoiseCfg {
            scale_m: g("/turbulence/scale_m", nd.scale_m),
            octaves: g("/turbulence/octaves", f64::from(nd.octaves)) as i32,
            evolve_ms: g("/turbulence/evolve_ms", nd.evolve_ms),
            large_scale_m: g("/turbulence/large_scale_m", 0.0),
            large_fade_agl_m: g("/turbulence/large_fade_agl_m", 150.0),
        };
        let ld = LeeCfg::default();
        let sink = g("/lee/sink_per_wind", ld.sink);
        let turb = g("/lee/turbulence_per_wind", ld.turb);
        let burst_scale = g("/lee/burst_scale_m", 120.0);
        let lee = LeeCfg {
            depth: g("/lee/depth_scale_m", ld.depth),
            relief: g("/lee/relief_scale_m", ld.relief),
            sink,
            turb,
            wind_red: g("/lee/wind_reduction", ld.wind_red),
            shear: g("/lee/shear_layer_m", 0.0),
            danger_min: g("/lee/danger_min_wind_ms", ld.danger_min),
            danger_full: g("/lee/danger_full_wind_ms", ld.danger_full),
            danger_sink: g("/lee/danger_sink_per_wind", sink),
            danger_turb: g("/lee/danger_turbulence_per_wind", turb),
            burst: g("/lee/burst_per_wind", 0.0),
            burst_k: noise.scale_m / burst_scale,
            burst_thr: g("/lee/burst_threshold", ld.burst_thr),
            burst_width: g("/lee/burst_width", ld.burst_width),
            reverse: g("/lee/rotor_reverse", 0.0),
            rotor_h: g("/lee/rotor_height_fraction", ld.rotor_h),
            rotor_max: g("/lee/rotor_max_amplitude_ms", 0.0),
            heat_full: g("/lee/heat_kill_wm2", 0.0),
            heat_wstar_k: g("/lee/heat_sigma_per_wstar", ld.heat_wstar_k),
        };
        AnalyticCfg {
            ground,
            ridge,
            lee,
            noise,
            mech_k: g("/turbulence/mech_per_wind", 0.14),
            mech_boost: g("/turbulence/mech_ground_boost", 1.0),
            mech_h: g("/turbulence/mech_ground_height_m", 150.0),
            vert_ratio: g("/turbulence/vertical_ratio", 0.7),
            advect_h: g("/turbulence/advection_height_m", 300.0),
        }
    }
}

/// Заданное состояние слота: конфиг, шум, нормировка Ленчова, кеши рельефа.
pub(crate) struct Cfgd {
    cfg: AnalyticCfg,
    noise: GustNoise,
    conv_norm: f64,
    grounds: RwLock<Vec<Arc<GroundField>>>,
}

/// Не больше кешей рельефа (пары «место, направление»).
const MAX_GROUNDS: usize = 4;

impl Cfgd {
    fn ground(&self, place: &Place, dir: [f32; 2], key: u64) -> Arc<GroundField> {
        let sig = PlaceSig::keyed(place, key);
        {
            let r = self
                .grounds
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(g) = r.iter().find(|g| g.matches(sig, dir)) {
                return g.clone();
            }
        }
        let g = Arc::new(GroundField::new(&self.cfg.ground, sig, dir));
        let mut w = self
            .grounds
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(e) = w.iter().find(|e| e.matches(sig, dir)) {
            return e.clone();
        }
        if w.len() >= MAX_GROUNDS {
            w.remove(0);
        }
        w.push(g.clone());
        g
    }
}

/// Точка опроса аналитики: рельеф сетки 30 м, ветер профиля в точке (GD берёт `agl` и `u` по
/// `GroundField`, не по `terrain`).
pub(crate) struct Pt<'a> {
    pub st: &'a Cfgd,
    pub c: &'a Ctx<'a>,
    pub place: &'a Place,
    pub gf: Arc<GroundField>,
    pub gs: GroundSample,
    pub pos: [f32; 3],
    pub agl: f64,
    pub u: f64,
    pub dir: [f64; 2],
}

impl<'a> Pt<'a> {
    fn new(st: &'a Cfgd, c: &'a Ctx<'a>) -> Self {
        let gf = st.ground(c.place, c.terms.ground_dir, c.terms.place_key);
        let gs = gf.sample(c.place, f64::from(c.pos[0]), f64::from(c.pos[2]));
        let y = f64::from(c.pos[1]);
        let agl = (y - gs.h).max(0.0);
        Pt {
            st,
            c,
            place: c.place,
            gf,
            gs,
            pos: c.pos,
            agl,
            u: c.terms.wind.speed_at_pos(agl, y),
            dir: c.terms.wind.dir(),
        }
    }

    pub fn ridge_lift(&self) -> f64 {
        ridge::lift(
            &self.st.cfg.ridge,
            &self.gf,
            self.place,
            self.pos,
            self.agl,
            self.u,
            self.dir,
        )
    }

    /// Опасность зоны от ветра прогноза на старте с поправкой на высоту точки.
    pub fn danger(&self) -> f64 {
        lee_danger_at(&self.st.cfg.lee, &self.c.terms.wind, self.pos[1])
    }

    pub fn burst_g(&self) -> f64 {
        self.st
            .cfg
            .lee
            .burst_g(&self.st.noise, self.pos, self.c.t, self.dir, self.u)
    }

    fn weather(&self) -> (f64, f64) {
        let w = &self.c.terms.weather;
        (
            w.f64_or("convective_turbulence_ms", 0.8),
            w.f64_or("cloudbase_agl_m", 1500.0),
        )
    }

    /// Ветка без поля (`air_velocity_at`).
    fn plain(&self) -> AnalyticMean {
        let cfg = &self.st.cfg.lee;
        let (u, y) = (self.u, f64::from(self.pos[1]));
        let mut lee = 0.0;
        let mut danger = 0.0;
        let mut relief = -1.0;
        let depth = self.gs.shadow - y;
        if depth > -cfg.shear && u > 0.0 {
            relief = self
                .gf
                .relief_at(self.place, f64::from(self.pos[0]), f64::from(self.pos[2]));
            lee = cfg.strength(depth, relief);
            if lee > 0.0 {
                danger = self.danger();
            }
        }
        let w_ridge = if u > 0.0 {
            self.ridge_lift() * (1.0 - lee)
        } else {
            0.0
        };
        let mut h = u * (1.0 - lee * cfg.wind_red);
        let mut w_lee = 0.0;
        if lee > 0.0 {
            let (conv, cb) = self.weather();
            let (hx, wy) = lee::flow(
                cfg,
                &self.st.noise,
                self.pos,
                self.c.t,
                self.dir,
                self.agl,
                u,
                lee,
                danger,
                relief,
                cfg.heat_factor(conv, cb),
            );
            h += hx;
            w_lee = wy;
        }
        AnalyticMean {
            h,
            w_ridge,
            w_lee,
            lee,
            danger,
            relief,
        }
    }
}

fn lee_danger_at(cfg: &LeeCfg, wind: &super::WindModel, y: f32) -> f64 {
    cfg.danger(wind.speed_ref * wind.altitude_factor(f64::from(y)))
}

/// Слот аналитики; до `configured` — без вклада.
pub struct AnalyticSlot {
    st: Option<Cfgd>,
}

impl AnalyticSlot {
    pub fn unconfigured() -> Self {
        AnalyticSlot { st: None }
    }

    pub fn new(configs: &Configs, seed: u64) -> Self {
        let cfg = AnalyticCfg::from_configs(configs);
        let noise = GustNoise::new(&cfg.noise, seed);
        let peak = (0..=100)
            .map(|i| lenschow(f64::from(i) / 100.0))
            .fold(0.0f64, f64::max);
        AnalyticSlot {
            st: Some(Cfgd {
                cfg,
                noise,
                conv_norm: 1.0 / peak.max(1.0e-4),
                grounds: RwLock::new(Vec::new()),
            }),
        }
    }

    pub fn cfg(&self) -> Option<&AnalyticCfg> {
        self.st.as_ref().map(|s| &s.cfg)
    }
}

impl Analytic for AnalyticSlot {
    fn configured(&self, configs: &Configs, seed: u64) -> Option<Arc<dyn Analytic>> {
        Some(Arc::new(AnalyticSlot::new(configs, seed)))
    }

    fn mean(&self, c: &Ctx) -> Option<AnalyticMean> {
        let st = self.st.as_ref()?;
        if c.a >= 1.0 {
            return None;
        }
        let p = Pt::new(st, c);
        Some(if c.a > 0.0 {
            strip::mean(&p, c.a)
        } else {
            p.plain()
        })
    }

    fn turb(
        &self,
        c: &Ctx,
        m: Option<&AnalyticMean>,
        _th: Option<&ThermalOut>,
    ) -> Option<AnalyticTurb> {
        let st = self.st.as_ref()?;
        let m = m?;
        let p = Pt::new(st, c);
        let cfg = &st.cfg;
        let (u, agl) = (p.u, p.agl);
        let rot = (cfg.lee.turb + (cfg.lee.danger_turb - cfg.lee.turb) * m.danger) * u * m.lee;
        let mech = cfg.mech_k
            * c.terms.weather.f64_or("mech_turbulence_k", 1.0)
            * u
            * (1.0 + cfg.mech_boost * (-agl / cfg.mech_h).exp());
        let (conv_amp, cb_agl_w) = p.weather();
        let mut conv = 0.0;
        let cloudbase_msl = p.gf.ground_ref(c.place) + cb_agl_w;
        if f64::from(c.pos[1]) < cloudbase_msl {
            let cb_agl = (cloudbase_msl - p.gs.h).max(1.0);
            conv = conv_amp * st.conv_norm * lenschow((agl / cb_agl).clamp(0.0, 1.0));
        }
        Some(AnalyticTurb {
            var: mech * mech + conv * conv + rot * rot,
            rot,
        })
    }

    fn gust(&self, c: &Ctx, amp: f64, fade: f64) -> [f64; 3] {
        let Some(st) = self.st.as_ref() else {
            return [0.0; 3];
        };
        if amp < 1.0e-3 {
            return [0.0; 3];
        }
        let p = Pt::new(st, c);
        let w = &c.terms.wind;
        let advect = w.speed_at(st.cfg.advect_h);
        let n = st
            .noise
            .gust_unit(c.pos, c.t, p.dir, advect, p.agl / st.noise.large_fade_agl);
        [
            n[0] * amp,
            n[1] * amp * st.cfg.vert_ratio * fade,
            n[2] * amp,
        ]
    }

    fn lee_danger(&self, c: &Ctx) -> Option<f64> {
        let st = self.st.as_ref()?;
        Some(lee_danger_at(&st.cfg.lee, &c.terms.wind, c.pos[1]))
    }

    fn relief(&self, c: &Ctx) -> Option<f64> {
        let st = self.st.as_ref()?;
        let gf = st.ground(c.place, c.terms.ground_dir, c.terms.place_key);
        Some(gf.relief_at(c.place, f64::from(c.pos[0]), f64::from(c.pos[2])))
    }

    fn cloudbase_msl(&self, t: &Terms, place: &Place) -> Option<f64> {
        let st = self.st.as_ref()?;
        let g = st.ground(place, t.ground_dir, t.place_key);
        Some(g.ground_ref(place) + t.weather.f64_or("cloudbase_agl_m", 1500.0))
    }

    fn background_wind(&self, t: &Terms, place: &Place, heights: &[f32], out: &mut [[f32; 2]]) {
        out.iter_mut().for_each(|o| *o = [0.0; 2]);
        let Some(st) = self.st.as_ref() else {
            return;
        };
        let gref = st
            .ground(place, t.ground_dir, t.place_key)
            .ground_ref(place);
        let d = t.wind.dir();
        for (o, &h) in out.iter_mut().zip(heights) {
            if !h.is_finite() {
                continue;
            }
            let hm = f64::from(h);
            let u = t.wind.speed_at_pos((hm - gref).max(0.0), hm);
            *o = [(d[0] * u) as f32, (d[1] * u) as f32];
        }
    }
}

/// Опасность подветренной зоны в точке для болтанки поля (RW-8): там, где аналитика не считала
/// (`AnalyticMean.danger` = 0 при `lee = 0`), а признак отрыва поля есть.
pub fn lee_danger(c: &Ctx) -> f64 {
    c.terms.slots.analytic.lee_danger(c).unwrap_or(0.0)
}

/// Превышение гребня против ветра над землёй в точке, м (для RW-8, когда в `AnalyticMean` его нет).
pub fn relief_at(c: &Ctx) -> f64 {
    c.terms.slots.analytic.relief(c).unwrap_or(0.0)
}

/// Фоновый ветер (профиль без рельефа и термиков) по высотам MSL: `[vx, vz]`. Подключение к
/// `AirModel::background_wind` — RW-12z.
pub fn background_wind(terms: &Terms, place: &Place, heights: &[f32], out: &mut [[f32; 2]]) {
    terms
        .slots
        .analytic
        .background_wind(terms, place, heights, out);
}

/// Нижняя кромка облаков, м над морем: средняя высота земли вокруг центра + `cloudbase_agl_m`.
pub fn cloudbase_msl(terms: &Terms, place: &Place) -> Option<f64> {
    terms.slots.analytic.cloudbase_msl(terms, place)
}
