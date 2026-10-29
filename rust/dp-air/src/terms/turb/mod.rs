//! Слагаемое `turb` (RW-8): болтанка поля воздуха (масштаб 3, AM-08) и шум порывов.
//!
//! - `sigma.rs` — `FieldTurbulence.sigma`: σ_u, σ_v, σ_w и масштабы вихрей по u*, сдвигу, Ri, w*
//!   поля; MIL-HDBK-1797.
//! - `spectrum.rs` — `GustSpectrum`: порывы со спектром фон Кармана (октавы шума `compat::noise`).
//! - `gust.rs` — `WindModel.gust_unit`: единичный шум порывов; [`gust`] — для шума аналитики
//!   (RW-9) и бурления в облаке (RW-11).
//! - `sep.rs` — признак отрыва, σ слоя смешения за гребнем, рывки вниз, доля обратного потока.
//!
//! Слот [`FieldTurb`] реализует `Turb`: [`Turb::mean`] — поправка среднего (обратный поток
//! эвристики), [`Turb::sigma`] — σ и шум поля. Порядок и формулы — буквально
//! `Atmosphere._air_velocity_field` (`atmosphere.gd` 1100–1213).
//!
//! Входы чужих слагаемых: `relief` и `lee` аналитики (RW-9; через `AnalyticMean`, без неё — 0),
//! σ термика/грозы/ротора (RW-10/11) складывает `sum`, не слот.
pub mod gust;
pub mod sep;
pub mod sigma;
pub mod spectrum;

use super::Ctx;
use super::slots::{AnalyticMean, Turb, TurbMean, TurbOut};
use super::sum::Mid;
use crate::Configs;
use crate::SampleMode;
use crate::field::runtime::ground_height;
use crate::field::wind_field::{T_HMIX, T_SIZE};
use crate::place::Place;
pub use gust::{GustCfg, GustUnit, gust};
use sigma::{TurbCfg, conv_norm, lenschow, taylor_stretch};
use spectrum::{GustSpectrum, SampleIn};
use std::cell::Cell;
use std::sync::{Arc, OnceLock};

/// Слот `Turb`: болтанка поля.
pub struct FieldTurb {
    cfg: TurbCfg,
    gusts: GustUnit,
    spec: GustSpectrum,
    conv_norm: f64,
    burst: OnceLock<(f64, f64)>,
}

/// Состояние поля в точке: то, что `mean` и `sigma` берут из поля (`_air_velocity_field`).
#[derive(Clone, Copy, Debug)]
pub struct FieldState {
    pub tb: [f32; T_SIZE],
    /// Скорость поля без доли, м/с.
    pub uf: f64,
    pub lee_f: f64,
    pub relief: f64,
    pub danger: f64,
    /// Ветер поля на уровне гребня `U_H`.
    pub u_h: f64,
    /// Скачок скорости слоя смешения ΔU (× признак отрыва).
    pub du: f64,
}

impl FieldTurb {
    pub fn new(configs: &Configs, seed: u64) -> Self {
        let gcfg = GustCfg::from_configs(configs);
        let seed = seed as i64;
        FieldTurb {
            cfg: TurbCfg::from_configs(configs),
            gusts: GustUnit::new(&gcfg, seed),
            spec: GustSpectrum::new(seed, gcfg.evolve_ms),
            conv_norm: conv_norm(),
            burst: OnceLock::new(),
        }
    }

    pub fn cfg(&self) -> &TurbCfg {
        &self.cfg
    }

    pub fn gusts(&self) -> &GustUnit {
        &self.gusts
    }

    pub fn spectrum(&self) -> &GustSpectrum {
        &self.spec
    }

    /// Среднее и СКО `g` рывка (один раз на сид).
    pub fn burst_stats(&self) -> (f64, f64) {
        *self
            .burst
            .get_or_init(|| sep::measure_burst(&self.cfg, &self.gusts))
    }

    /// Слот для `Slots`.
    pub fn slot(configs: &Configs, seed: u64) -> Arc<dyn Turb> {
        Arc::new(FieldTurb::new(configs, seed))
    }

    fn z0(c: &Ctx) -> f64 {
        c.fs.levels().first().map_or(0.1, |l| l.z0())
    }

    /// Величины поля и зоны отрыва в точке (`a > 0`).
    pub fn state(&self, c: &Ctx, am: Option<&AnalyticMean>) -> FieldState {
        let cfg = &self.cfg;
        let tb9 = c.fs.sample_turb(c.pos, c.ground);
        let mut tb = [0f32; T_SIZE];
        tb.copy_from_slice(&tb9[..T_SIZE]);
        let uf = (c.fw[0] * c.fw[0] + c.fw[2] * c.fw[2]).sqrt() / c.a;
        let lee_f = sep::lee(cfg, Self::z0(c), uf, c.agl, &tb);
        let lee_a = am.map_or(0.0, |m| m.lee);
        let mut danger = 0.0;
        let mut relief = am.map_or(-1.0, |m| m.relief);
        if lee_f > 0.0 || lee_a > 0.0 {
            let w = &c.terms.wind;
            danger = sep::lee_danger(cfg, w.speed_ref * w.altitude_factor(f64::from(c.pos[1])));
        }
        // превышение гребня — из аналитики (RW-9); без неё неизвестно: 0
        if relief < 0.0 {
            relief = 0.0;
        }
        let mut u_h = uf;
        if lee_f > 0.0 && relief > c.agl {
            let p = [c.pos[0], c.ground + relief as f32, c.pos[2]];
            let fh = c.fs.sample(p, c.ground);
            if fh.share > 0.0 {
                u_h = (fh.v[0] * fh.v[0] + fh.v[2] * fh.v[2]).sqrt() / fh.share;
            }
        }
        let du = (u_h - uf).max(0.0) * lee_f;
        FieldState {
            tb,
            uf,
            lee_f,
            relief,
            danger,
            u_h,
            du,
        }
    }

    /// Поправка среднего горизонтали: обратный поток эвристики у земли, только где пузырь отрыва
    /// решателем не разрешён (`-a·0,22·U_H·lee·danger·unres·exp(−agl/(rotor_h·r))`).
    pub fn reverse_dh(&self, st: &FieldState, a: f64, agl: f64, dx: f64) -> f64 {
        let cfg = &self.cfg;
        if st.lee_f > 0.0 && st.danger > 0.0 {
            let unres = sep::reverse_unresolved(cfg, st.relief, dx);
            if unres > 0.0 {
                return -(a
                    * cfg.reverse
                    * st.u_h
                    * st.lee_f
                    * st.danger
                    * unres
                    * (-agl / (cfg.rotor_h * st.relief).max(1.0)).exp());
            }
        }
        0.0
    }
}

thread_local! {
    static GROUND_REF: Cell<(usize, usize, f64)> = const { Cell::new((0, 0, 0.0)) };
}

/// Средняя высота земли вокруг начала координат (`GroundField.mean_height`, `_update_cloudbase`);
/// кеш по месту — на поток.
fn ground_ref(cfg: &TurbCfg, place: &Place) -> f64 {
    let key = (place as *const Place as usize, place.heights().len());
    let (p, n, v) = GROUND_REF.with(Cell::get);
    if (p, n) == key {
        return v;
    }
    let s = cfg.ground_samples;
    let (mut sum, mut cnt) = (0.0f64, 0i64);
    for j in 0..s {
        for i in 0..s {
            let d = (s - 1).max(1) as f64;
            let u = (i as f64 / d) * 2.0 - 1.0;
            let v2 = (j as f64 / d) * 2.0 - 1.0;
            if u * u + v2 * v2 > 1.0 {
                continue;
            }
            sum += f64::from(ground_height(
                place,
                (u * cfg.ground_radius) as f32,
                (v2 * cfg.ground_radius) as f32,
            ));
            cnt += 1;
        }
    }
    let r = sum / cnt.max(1) as f64;
    GROUND_REF.with(|c| c.set((key.0, key.1, r)));
    r
}

impl Turb for FieldTurb {
    fn mean(&self, c: &Ctx, m: Option<&AnalyticMean>) -> Option<TurbMean> {
        let st = self.state(c, m);
        let dh = if st.lee_f > 0.0 && st.danger > 0.0 {
            self.reverse_dh(&st, c.a, c.agl, c.fs.sample_dx(c.pos))
        } else {
            0.0
        };
        Some(TurbMean {
            dh,
            du: st.du,
            danger: st.danger,
        })
    }

    fn sigma(&self, c: &Ctx, mid: &Mid) -> Option<TurbOut> {
        let cfg = &self.cfg;
        let st = self.state(c, mid.analytic.as_ref());
        // конвективная болтанка аналитики — когда в поле нет данных о нагреве
        let mut conv_a = 0.0;
        if f64::from(st.tb[T_HMIX]) <= 0.0 {
            let cb_msl =
                ground_ref(cfg, c.place) + c.terms.weather.f64_or("cloudbase_agl_m", 1500.0);
            if f64::from(c.pos[1]) < cb_msl {
                let cb_agl = (cb_msl - f64::from(c.ground)).max(1.0);
                let amp = c.terms.weather.f64_or("convective_turbulence_ms", 0.8);
                conv_a = amp * self.conv_norm * lenschow((c.agl / cb_agl).clamp(0.0, 1.0));
            }
        }
        let w = &c.terms.wind;
        let (du, danger) = mid.turb.map_or((st.du, st.danger), |t| (t.du, t.danger));
        let st = FieldState { du, danger, ..st };
        Some(self.turb_out(
            &st,
            &PointIn {
                pos: c.pos,
                t: c.t,
                agl: c.agl,
                u: c.u,
                z0: Self::z0(c),
                mh: [mid.v[0], mid.v[2]],
                conv_a,
                full: c.mode == SampleMode::Full,
                dir: w.dir(),
                advect: w.speed_at(cfg.advection_height),
            },
        ))
    }
}

/// Входы `turb_out`, которые слот берёт из `Ctx` и суммы (не из поля).
#[derive(Clone, Copy, Debug)]
pub struct PointIn {
    pub pos: [f32; 3],
    /// Время атмосферы, с.
    pub t: f64,
    pub agl: f64,
    /// Ветер профиля в точке (перенос пятен рывков).
    pub u: f64,
    /// Шероховатость уровня поля, м.
    pub z0: f64,
    /// Средний ветер в точке `(x, z)` после `_extra_flow`.
    pub mh: [f64; 2],
    /// Конвективная σ аналитики (если в поле нет данных о нагреве), м/с.
    pub conv_a: f64,
    /// FULL: шум и рывки считаются; MEAN — только σ.
    pub full: bool,
    /// `WindModel.dir`.
    pub dir: [f64; 2],
    /// Скорость переноса шума `wind.speed_at(advection_height_m)`.
    pub advect: f64,
}

impl FieldTurb {
    /// Болтанка поля в точке по величинам поля и зоне отрыва: σ, шум спектра, рывки слоя смешения
    /// (`_air_velocity_field` после `_extra_flow`, до ограничителей и слияния с термиком — их
    /// делает `sum`).
    pub fn turb_out(&self, st: &FieldState, p: &PointIn) -> TurbOut {
        let cfg = &self.cfg;
        let sg = sigma::sigma(
            cfg,
            p.z0,
            p.agl,
            &st.tb,
            [p.conv_a, p.conv_a * cfg.vertical_ratio],
            st.uf,
        );
        let mut sep_s = sep::sep_sigma(cfg, st.du);
        // рывки вниз слоя смешения (нулевое среднее): их доля в σ_w вычитается из гауссовой
        let hard_f = st.du * st.danger;
        let mut w_burst = 0.0;
        if hard_f > 1.0e-3 {
            let amp_b = cfg.burst_per_du * hard_f;
            let (g_mean, g_std) = self.burst_stats();
            if p.full {
                w_burst =
                    -amp_b * (sep::burst_g(cfg, &self.gusts, p.pos, p.t, p.dir, p.u) - g_mean);
            }
            let s_b = amp_b * g_std;
            sep_s[1] = (sep_s[1] * sep_s[1] - s_b * s_b).max(0.0).sqrt();
        }
        let s_u = sg.s_u.max(sep_s[0]);
        let s_v = sg.s_v.max(sep_s[0]);
        let s_w = sg.s_w.max(sep_s[1]);
        let mut n = [0.0; 3];
        if p.full {
            let ml = (p.mh[0] * p.mh[0] + p.mh[1] * p.mh[1]).sqrt();
            let stretch = taylor_stretch(p.advect, ml, p.agl);
            let l_sep = cfg.sep_scale * st.relief.max(0.0) * st.lee_f;
            let r = self.spec.sample(&SampleIn {
                pos: p.pos,
                t: p.t,
                advect: p.advect,
                dir: p.dir,
                l_u: (sg.l_u * stretch).max(l_sep),
                l_w: (sg.l_w * stretch).max(l_sep),
                l_2: sg.l_c,
                f_a: sg.fu_c,
                f_c: sg.fv_c,
            });
            n = [f64::from(r[0]), f64::from(r[1]), f64::from(r[2])];
        }
        TurbOut {
            s_u,
            s_v,
            s_w,
            sep: sep_s,
            n,
            w_burst,
        }
    }
}
