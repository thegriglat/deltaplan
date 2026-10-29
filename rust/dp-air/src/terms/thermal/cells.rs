//! Жизнь термиков по клеткам (`thermal_field.gd`, аналитический путь): мир разбит на клетки
//! `thermal_spacing_m`, повёрнутые по ветру; у клетки период и фаза, в цикле термик рождается или
//! нет. Термик цикла — чистая функция (клетка, цикл): сид `_mix(ia, ic, cy)`, погода, солнце и
//! кромка берутся на момент рождения. Порядок `randf` в `spawn` значим и повторяет GDScript.
//!
//! Облачные зацепки (`shade_at`) — через [`CloudHooks`](super::CloudHooks), нулевые до RW-11;
//! источники из поля (`_spawn_air`) — RW-10e.
use super::cfg::ThermalCfg;
use super::life::{AtmoThermal, cb_thermal_chance, pair};
use super::{CloudHooks, GroundSource};
use crate::compat::rng::Pcg32;
use crate::terms::{Terms, WeatherView, WindModel};
use std::collections::HashMap;
use std::sync::Arc;

/// Входы жизни термиков на момент сборки: конфиг, погода, ветер, система клеток, кромка.
#[derive(Clone, Debug)]
pub struct Setup {
    pub cfg: ThermalCfg,
    pub w: WeatherView,
    pub wind: WindModel,
    pub seed: i64,
    /// Ось клеток `a` (по ветру) и `c` (поперёк), `Vector2` GDScript.
    pub ax: [f32; 2],
    pub cx: [f32; 2],
    /// Сила улиц 0..1 и расстояние между ними, м.
    pub street: f64,
    pub street_spacing: f64,
    pub spacing: f64,
    pub cloudbase_msl: f64,
    /// Доля солнечного прогрева (перистая пелена).
    pub ins: f64,
    /// Направление на солнце (для теней облаков).
    pub sun: [f64; 3],
    /// Только статичные термики.
    pub static_only: bool,
    /// Край термика для σ: `edge_factor · thermal_edge_k`, `edge_width`.
    pub edge_k: f64,
    pub edge_w: f64,
}

/// Память о циклах клеток: чистые результаты, не физика (GD: `_cells`, `_empty_cycles`).
#[derive(Default)]
pub struct Memo {
    cells: HashMap<(i64, i64), (f32, f32)>,
    /// id цикла → (термик или `None`, до какого момента помнить).
    ids: HashMap<i64, (Option<Arc<AtmoThermal>>, f64)>,
    prune_t: f64,
}

impl Memo {
    pub fn new() -> Self {
        Memo {
            prune_t: -1.0e18,
            ..Default::default()
        }
    }

    /// Раз в минуту забыть циклы, которые уже не понадобятся.
    pub fn prune(&mut self, t: f64) {
        if t - self.prune_t < 60.0 && t >= self.prune_t {
            return;
        }
        self.prune_t = t;
        self.ids.retain(|_, (_, forget)| t <= *forget);
    }

    pub fn len(&self) -> usize {
        self.ids.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }
}

impl Setup {
    /// Те же входы жизни термиков (память о циклах остаётся верной)?
    pub fn same_env(&self, o: &Setup) -> bool {
        self.seed == o.seed
            && self.cfg == o.cfg
            && self.w == o.w
            && self.wind.dir() == o.wind.dir()
            && self.wind.speed_ref == o.wind.speed_ref
            && self.wind.profile_params() == o.wind.profile_params()
            && self.sun == o.sun
            && self.static_only == o.static_only
            && self.cloudbase_msl == o.cloudbase_msl
            && self.ins == o.ins
    }

    /// Сборка из снимка слагаемых; `cfg` — разобранный конфиг, `ground_ref` — средняя высота
    /// земли вокруг (0, 0) ([`mean_height`]), отсчёт кромки облаков.
    pub fn new(terms: &Terms, cfg: ThermalCfg, ground_ref: f64) -> Setup {
        let w = terms.weather.clone();
        let wind = terms.wind.clone();
        let cb_agl = w.f64_or("cloudbase_agl_m", 0.0);
        let cloudbase_msl = ground_ref + cb_agl;
        let ins = 1.0 - crate::weather::sun_block_cover(w.map()) * cfg.cirrus_block;
        let sun = match terms.sun {
            Some(s) if s.iter().all(|v| v.is_finite()) => {
                [f64::from(s[0]), f64::from(s[1]), f64::from(s[2])]
            }
            _ => {
                let el = cfg.sun_elevation_deg.to_radians();
                let az = cfg.sun_azimuth_deg.to_radians();
                [az.sin() * el.cos(), el.sin(), -az.cos() * el.cos()]
            }
        };
        let static_only = terms.statics_mode == 1
            || (terms.statics_mode == 0 && w.str_or("thermal_mode", "dynamic") == "static");
        let edge_k = cfg.edge_factor * w.f64_or("thermal_edge_k", 1.0);
        let edge_w = cfg.edge_width;
        let mut s = Setup {
            seed: terms.seed as i64,
            ax: [0.0, 1.0],
            cx: [-1.0, 0.0],
            street: 0.0,
            street_spacing: 3000.0,
            spacing: w.f64_or("thermal_spacing_m", 2000.0),
            cloudbase_msl,
            ins,
            sun,
            static_only,
            edge_k,
            edge_w,
            cfg,
            w,
            wind,
        };
        s.update_wind_frame();
        s
    }

    /// `update_wind_frame`: ось `a` по ветру, улицы.
    fn update_wind_frame(&mut self) {
        let wd = self.wind.dir();
        let mut d = [wd[0] as f32, wd[1] as f32];
        if d[0] * d[0] + d[1] * d[1] < 1.0e-6 {
            d = [0.0, 1.0];
        }
        let l = (d[0] * d[0] + d[1] * d[1]).sqrt();
        self.ax = [d[0] / l, d[1] / l];
        self.cx = [-self.ax[1], self.ax[0]];
        let (k, sp) = self.street_for();
        self.street = k;
        self.street_spacing = sp;
    }

    /// Сила улиц 0..1 и расстояние между ними, м (`_street_for`).
    fn street_for(&self) -> (f64, f64) {
        let cfg = &self.cfg;
        let cb_agl = self.w.f64_or("cloudbase_agl_m", 0.0);
        let s_ms = self.wind.speed_at(cb_agl * 0.5);
        let k = self.w.f64_or("street_strength", 0.0)
            * ((s_ms - cfg.street_min_wind_ms)
                / (cfg.street_full_wind_ms - cfg.street_min_wind_ms).max(0.01))
            .clamp(0.0, 1.0);
        (k, cfg.street_spacing_factor * cb_agl)
    }

    /// Период 630–1560 с у каждой клетки: сумма границ диапазонов `gap/grow/mature/decay`.
    fn period_range(&self) -> (f64, f64) {
        let c = &self.cfg;
        let lo = c.grow_s[0] + c.mature_s[0] + c.decay_s[0] + c.gap_s[0];
        let hi = c.grow_s[1] + c.mature_s[1] + c.decay_s[1] + c.gap_s[1];
        (lo, hi)
    }

    /// `_mix(a, b, c)`: сид RNG и id цикла (целые GDScript — `i64` с переносом).
    pub fn mix(&self, a: i64, b: i64, c: i64) -> i64 {
        let mut h = self.seed.wrapping_mul(73_856_093);
        h = (h ^ a.wrapping_mul(19_349_663)) & 0x7FFF_FFFF;
        h = h.wrapping_mul(31).wrapping_add(b.wrapping_mul(83_492_791)) & 0x7FFF_FFFF;
        h = h
            .wrapping_mul(31)
            .wrapping_add(c.wrapping_mul(2_654_435_761))
            & 0x7FFF_FFFF;
        h
    }

    /// `_cell_params`: (период, фаза) клетки, `Vector2` (f32).
    pub fn cell_params(&self, memo: &mut Memo, ia: i64, ic: i64) -> (f32, f32) {
        if let Some(p) = memo.cells.get(&(ia, ic)) {
            return *p;
        }
        let mut rng = Pcg32::from_seed(self.mix(ia, ic, 0x51F1) as u64);
        let (lo, hi) = self.period_range();
        let period = rng.randf_range(lo as f32, hi as f32);
        let phase = (f64::from(rng.randf()) * f64::from(period)) as f32;
        let p = (period, phase);
        memo.cells.insert((ia, ic), p);
        p
    }

    /// Клетка фокуса (a, c).
    pub fn focus_cell(&self, fx: f64, fz: f64) -> (i64, i64) {
        let (fx, fz) = (fx as f32, fz as f32);
        let a = fx * self.ax[0] + fz * self.ax[1];
        let c = fx * self.cx[0] + fz * self.cx[1];
        (
            (f64::from(a) / self.spacing).floor() as i64,
            (f64::from(c) / self.spacing).floor() as i64,
        )
    }

    /// Круг генерации в клетках: `(радиус / шаг + 1)²`.
    pub fn circle_r2(&self) -> f64 {
        let r = self.cfg.generation_radius_m / self.spacing + 1.0;
        r * r
    }

    /// До какого момента после начала цикла `t_start` термик жив с облаком (`_reach_of`).
    fn reach_of(&self, period: f64) -> f64 {
        let cb = cb_thermal_chance(&self.w) > 0.0;
        period * if cb { self.cfg.cb_factor() } else { 1.0 } + self.cfg.cloud_linger_s
    }

    /// Все клетки круга вокруг фокуса `(fx, fz)` на момент `t`: живые термики цикла (`_gen_cell`).
    pub fn generate(
        &self,
        memo: &mut Memo,
        ground: &dyn GroundSource,
        hooks: &dyn CloudHooks,
        t: f64,
        focus: [f64; 2],
        out: &mut Vec<Arc<AtmoThermal>>,
    ) {
        if self.spacing <= 0.0 || !self.spacing.is_finite() {
            return;
        }
        let (fa, fc) = self.focus_cell(focus[0], focus[1]);
        let r2 = self.circle_r2();
        let n = (self.cfg.generation_radius_m / self.spacing).ceil() as i64;
        for dc in -n..=n {
            for da in -n..=n {
                if ((da * da + dc * dc) as f64) > r2 {
                    continue;
                }
                self.gen_cell(memo, ground, hooks, fa + da, fc + dc, t, out);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn gen_cell(
        &self,
        memo: &mut Memo,
        ground: &dyn GroundSource,
        hooks: &dyn CloudHooks,
        ia: i64,
        ic: i64,
        t: f64,
        out: &mut Vec<Arc<AtmoThermal>>,
    ) {
        let (px, py) = self.cell_params(memo, ia, ic);
        let (period, phase) = (f64::from(px), f64::from(py));
        let cycle = ((t + phase) / period).floor() as i64;
        let cbf = self.cfg.cb_factor();
        let linger = self.cfg.cloud_linger_s;
        let mut k = 0;
        loop {
            let cy = cycle - k;
            let t_start = cy as f64 * period - phase;
            k += 1;
            if k > 1 {
                if t_start + period * cbf + linger < t {
                    break;
                }
                if t_start + self.reach_of(period) < t {
                    continue;
                }
            }
            self.ensure(memo, ground, hooks, ia, ic, cy, t_start, period, t, out);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn ensure(
        &self,
        memo: &mut Memo,
        ground: &dyn GroundSource,
        hooks: &dyn CloudHooks,
        ia: i64,
        ic: i64,
        cy: i64,
        t_start: f64,
        period: f64,
        t: f64,
        out: &mut Vec<Arc<AtmoThermal>>,
    ) {
        let id = self.mix(ia, ic, cy) | 1;
        let linger = self.cfg.cloud_linger_s;
        if let Some((th, _)) = memo.ids.get(&id) {
            if let Some(th) = th
                && t <= th.t_end() + linger
            {
                out.push(th.clone());
            }
            return;
        }
        let mut th = self.spawn(ground, hooks, ia, ic, id, t_start, period);
        let forget = t_start + self.reach_of(period);
        if let Some(th) = th.as_mut() {
            th.cycle_forget = forget;
        }
        let th = th.map(Arc::new);
        match &th {
            Some(a) if t <= a.t_end() + linger => {
                out.push(a.clone());
                memo.ids.insert(id, (th, forget));
            }
            _ => {
                memo.ids.insert(id, (None, forget));
            }
        }
    }

    /// Термик цикла, рождённого в `t_start` (`_spawn`, путь клеток).
    #[allow(clippy::too_many_arguments)]
    pub fn spawn(
        &self,
        ground: &dyn GroundSource,
        hooks: &dyn CloudHooks,
        ia: i64,
        ic: i64,
        id: i64,
        t_start: f64,
        period: f64,
    ) -> Option<AtmoThermal> {
        let cfg = &self.cfg;
        let w = &self.w;
        let mut rng = Pcg32::from_seed(id as u64);
        let rf = |rng: &mut Pcg32| f64::from(rng.randf());
        let rr = |rng: &mut Pcg32, a: f64, b: f64| f64::from(rng.randf_range(a as f32, b as f32));
        if rf(&mut rng) > w.f64_or("thermal_duty", 0.0) {
            return None;
        }
        // Источник: лучшая по освещённости из нескольких точек клетки, с подтяжкой к улице.
        let street = self.street as f32;
        let street_sp = self.street_spacing as f32;
        let mut best_sun = -1.0f64;
        let mut best = [0.0f32; 2];
        for _ in 0..cfg.source_candidates {
            let a = (ia as f64 + rf(&mut rng)) * self.spacing;
            let mut c = (ic as f64 + rf(&mut rng)) * self.spacing;
            if street > 0.0 {
                let sp = f64::from(street_sp);
                let line = (c / sp).round() * sp;
                let tgt = line + rr(&mut rng, -0.1, 0.1) * sp;
                c += (tgt - c) * f64::from(street);
            }
            let (a32, c32) = (a as f32, c as f32);
            let p = [
                self.ax[0] * a32 + self.cx[0] * c32,
                self.ax[1] * a32 + self.cx[1] * c32,
            ];
            let (px, pz) = (f64::from(p[0]), f64::from(p[1]));
            let mut s = ground.source(px, pz, t_start).clamp(0.0, 1.0) * rr(&mut rng, 0.85, 1.0);
            // над водой источника нет
            if s > best_sun.max(0.0) && ground.is_water(px, pz) {
                s = 0.0;
            }
            if s > best_sun {
                best_sun = s;
                best = p;
            }
        }
        let (bx, bz) = (f64::from(best[0]), f64::from(best[1]));
        // тень облака поля на источнике (RW-11; пока 0)
        let shade = hooks.shade_at(bx, bz, self.sun) * cfg.cloud_shade_factor;
        best_sun *= 1.0 - shade;
        // перистая пелена
        let ins = self.ins;
        best_sun *= ins;
        if best_sun < cfg.sun_min {
            return None;
        }
        if rf(&mut rng) > best_sun.powf(cfg.source_frequency_exponent) {
            return None;
        }
        let mut th = AtmoThermal::blank(id);
        th.noise_seed = id;
        th.cell = (ia, ic);
        let h = ground.height(bx, bz);
        th.src = [best[0], h as f32, best[1]];
        let hs = f64::from(th.src[1]);
        th.top = self.cloudbase_msl.max(hs + cfg.min_depth_m);
        let [smin, smax] = pair(w, "thermal_strength_ms", [0.0, 0.0]);
        let u = rf(&mut rng).powf(1.4); // слабых больше, чем сильных
        let sun_k = best_sun.powf(cfg.sun_strength_exponent);
        th.strength = smin + (smax - smin) * u;
        th.strength *= 1.0 + (sun_k - 1.0) * 0.5;
        th.strength = th.strength.max(smin) * (1.0 - shade);
        th.strength *= ins.powf(cfg.insolation_strength_exponent);
        let [rmin, rmax] = pair(w, "thermal_radius_m", [0.0, 0.0]);
        let q = (0.5 * rf(&mut rng) + 0.5 * u).clamp(0.0, 1.0);
        th.radius = rmin + (rmax - rmin) * q;
        // Изредка — очень сильные термики (8–9 м/с).
        let ext = pair(w, "thermal_extreme_ms", [f64::NAN, f64::NAN]);
        let has_ext = w
            .get("thermal_extreme_ms")
            .and_then(|v| v.as_array())
            .is_some_and(|a| a.len() == 2);
        if rf(&mut rng) < w.f64_or("thermal_extreme_chance", 0.0) && has_ext {
            th.strength = rr(&mut rng, ext[0], ext[1]) * sun_k * ins;
            th.radius = th.radius.max(rmax);
        }
        th.set_life(cfg, &mut rng, t_start, period);
        let r1 = rf(&mut rng);
        th.setup_cloud(w, r1);
        let r2 = rf(&mut rng);
        th.setup_cb(cfg, w, r2);
        th.apply_wind(cfg, &self.wind, self.street, None);
        Some(th)
    }
}

/// Средняя высота земли вокруг (0, 0): отсчёт кромки облаков (`GroundField.mean_height`).
pub fn mean_height(ground: &dyn GroundSource, cfg: &ThermalCfg) -> f64 {
    let n = cfg.ref_samples;
    let mut sum = 0.0;
    let mut cnt = 0usize;
    let den = n.saturating_sub(1).max(1) as f64;
    for j in 0..n {
        for i in 0..n {
            let u = i as f64 / den * 2.0 - 1.0;
            let v = j as f64 / den * 2.0 - 1.0;
            if u * u + v * v > 1.0 {
                continue;
            }
            sum += ground.height(u * cfg.ref_radius_m, v * cfg.ref_radius_m);
            cnt += 1;
        }
    }
    sum / cnt.max(1) as f64
}
