//! Поле облачности региона: прогностическая модель на сетке уровня
//! региона. Столбец несёт активную долю `a`, пассивную `p`, мощность `d` и переразвитие `od`.
//! `da/dt = (a_u − a)/τ_form`, `dp/dt = a/τ_life − p/τ_evap(d)`, `dd/dt = (D* − d)/τ_deepen`
//! при подъёме и `−d/τ_evap` без него; снос - полулагранжев перенос ветром у основания.
//!
//! Детерминизм: фиксированный шаг `step_s`, без часов и RNG; одинаковые входы и `t` - побитно те
//! же массивы. Массивы - `f32`, локальная арифметика - `f64`, как в эталоне. Сеть (снимок К4) и
//! текстура К2 не переносятся.
use super::cfg::FieldCfg;
use super::sources::{Grid, PrepIn, prepare};
use crate::field::wind_field::Field;
use crate::hash::hash_v2i;
use crate::terms::WeatherView;
use crate::terms::thermal_air::AirThermals;
use std::sync::Arc;

/// Входы поля на момент (`CloudField.set_inputs`).
pub struct FieldInputs {
    pub grid: Grid,
    pub wind_field: Option<Arc<Field>>,
    pub air: Option<Arc<AirThermals>>,
    /// Живые термики для аналитического пути (когда `air` нет).
    pub thermals: Option<Vec<super::sources::ThermalSnap>>,
    pub weather: WeatherView,
    pub cloudbase_msl: Option<f64>,
    pub ground_ref: Option<f64>,
    pub seed: i64,
    pub wind_at: Arc<dyn Fn(f64) -> [f64; 2] + Send + Sync>,
}

#[derive(Clone)]
pub struct CloudField {
    pub cfg: FieldCfg,
    pub nx: usize,
    pub ny: usize,
    pub dx: f64,
    pub x0: f64,
    pub y0: f64,
    /// Основание (LCL), м над морем.
    pub base_msl: f64,
    pub cover: Vec<f32>,
    pub depth: Vec<f32>,
    pub stage: Vec<f32>,
    pub activity: Vec<f32>,
    pub bg_cover: f64,
    pub bg_depth: f64,
    pub time: f64,
    pub hc: Vec<f32>,
    a: Vec<f32>,
    p: Vec<f32>,
    d: Vec<f32>,
    od: Vec<f32>,
    tower: Vec<u8>,
    tower_key: Option<(i64, f64)>,
    au0: Vec<f32>,
    au1: Vec<f32>,
    ds0: Vec<f32>,
    ds1: Vec<f32>,
    vx: Vec<f32>,
    vz: Vec<f32>,
    has_inputs: bool,
    blend_t0: f64,
    blend_s: f64,
    depth_day: f64,
    overdev: f64,
    seed: i64,
    adv_disp: f64,
    adv_dt: f64,
    mean_v: [f32; 2],
    started: bool,
}

fn clampf(x: f64, lo: f64, hi: f64) -> f64 {
    if x < lo {
        lo
    } else if x > hi {
        hi
    } else {
        x
    }
}

impl CloudField {
    pub fn new(cfg: FieldCfg) -> Self {
        CloudField {
            cfg,
            nx: 0,
            ny: 0,
            dx: 400.0,
            x0: 0.0,
            y0: 0.0,
            base_msl: 0.0,
            cover: Vec::new(),
            depth: Vec::new(),
            stage: Vec::new(),
            activity: Vec::new(),
            bg_cover: 0.0,
            bg_depth: 0.0,
            time: 0.0,
            hc: Vec::new(),
            a: Vec::new(),
            p: Vec::new(),
            d: Vec::new(),
            od: Vec::new(),
            tower: Vec::new(),
            tower_key: None,
            au0: Vec::new(),
            au1: Vec::new(),
            ds0: Vec::new(),
            ds1: Vec::new(),
            vx: Vec::new(),
            vz: Vec::new(),
            has_inputs: false,
            blend_t0: 0.0,
            blend_s: 0.0,
            depth_day: 800.0,
            overdev: 0.0,
            seed: 0,
            adv_disp: 0.0,
            adv_dt: 0.0,
            mean_v: [0.0; 2],
            started: false,
        }
    }

    pub fn grid(&self) -> Grid {
        Grid {
            nx: self.nx,
            ny: self.ny,
            dx: self.dx,
            x0: self.x0,
            y0: self.y0,
        }
    }

    pub fn setup_grid(&mut self, g: Grid) {
        self.nx = g.nx;
        self.ny = g.ny;
        self.dx = g.dx;
        self.x0 = g.x0;
        self.y0 = g.y0;
        let n = g.nx * g.ny;
        for arr in [
            &mut self.cover,
            &mut self.depth,
            &mut self.stage,
            &mut self.activity,
            &mut self.a,
            &mut self.p,
            &mut self.d,
            &mut self.od,
            &mut self.au0,
            &mut self.au1,
            &mut self.ds0,
            &mut self.ds1,
            &mut self.vx,
            &mut self.vz,
            &mut self.hc,
        ] {
            arr.clear();
            arr.resize(n, 0.0);
        }
        self.tower.clear();
        self.tower.resize(n, 0);
        self.tower_key = None;
        self.has_inputs = false;
        self.blend_s = 0.0;
        self.started = false;
    }

    /// Следующий вызов `step_to` начнёт с разгона (`start_at`).
    pub fn invalidate(&mut self) {
        self.started = false;
    }

    /// Входы: применяются со следующего шага; переход от прежних - `input_blend_s`.
    pub fn set_inputs(&mut self, inp: &FieldInputs) {
        if self.nx == 0 || self.grid() != inp.grid {
            self.setup_grid(inp.grid);
        }
        let n = self.nx * self.ny;
        if let Some(z) = inp
            .weather
            .get("_derived")
            .and_then(|d| d.get("z_lcl_msl_m"))
            .and_then(|v| v.as_f64())
        {
            self.base_msl = z;
        } else if let Some(c) = inp.cloudbase_msl {
            self.base_msl = c;
        }
        self.depth_day = inp
            .weather
            .f64_or("cloud_depth_m", self.cfg.depth_day_default_m);
        self.overdev = clampf(inp.weather.f64_or("overdevelopment_chance", 0.0), 0.0, 1.0);
        let seed = inp.seed;
        if self.tower_key != Some((seed, self.overdev)) || self.tower.len() != n {
            self.seed = seed;
            self.mark_towers();
            self.tower_key = Some((seed, self.overdev));
        }
        let wind_at = inp.wind_at.clone();
        let pin = PrepIn {
            wf: inp.wind_field.as_deref(),
            air: inp.air.as_deref(),
            thermals: inp.thermals.as_deref(),
            weather: &inp.weather,
            ground_ref: inp.ground_ref,
            wind_at: &*wind_at,
        };
        let prep = prepare(self.grid(), self.base_msl, &pin, &self.cfg);
        let blend_s = self.cfg.input_blend_s;
        if self.has_inputs && blend_s > 0.0 && self.started {
            let f = self.blend_frac();
            for c in 0..n {
                let (a0, a1) = (f64::from(self.au0[c]), f64::from(self.au1[c]));
                self.au0[c] = (a0 + (a1 - a0) * f) as f32;
                let (d0, d1) = (f64::from(self.ds0[c]), f64::from(self.ds1[c]));
                self.ds0[c] = (d0 + (d1 - d0) * f) as f32;
            }
            self.blend_t0 = self.time;
            self.blend_s = blend_s;
        } else {
            self.au0 = prep.au.clone();
            self.ds0 = prep.ds.clone();
            self.blend_s = 0.0;
        }
        self.au1 = prep.au;
        self.ds1 = prep.ds;
        self.vx = prep.vx;
        self.vz = prep.vz;
        self.hc = prep.hc;
        self.mean_v = prep.mean_v;
        self.has_inputs = true;
    }

    fn blend_frac(&self) -> f64 {
        if self.blend_s <= 0.0 {
            return 1.0;
        }
        clampf((self.time - self.blend_t0) / self.blend_s, 0.0, 1.0)
    }

    /// Пустое поле, время `t − spinup_s`, поле «запущено»: дальше `step_to` разгоняет его.
    pub fn begin_spinup(&mut self, t: f64) {
        for arr in [
            &mut self.cover,
            &mut self.depth,
            &mut self.stage,
            &mut self.activity,
            &mut self.a,
            &mut self.p,
            &mut self.d,
            &mut self.od,
        ] {
            arr.fill(0.0);
        }
        self.bg_cover = 0.0;
        self.bg_depth = 0.0;
        self.blend_s = 0.0;
        self.au0 = self.au1.clone();
        self.ds0 = self.ds1.clone();
        self.adv_disp = 0.0;
        self.adv_dt = 0.0;
        self.time = t - self.cfg.spinup_s;
        self.started = true;
    }

    /// Пустое поле + разгон до `t` от текущих входов.
    pub fn reset(&mut self, t: f64) {
        self.begin_spinup(t);
        self.advance(t);
        self.time = t;
    }

    /// Шаги фиксированной длины до `t`; назад или скачок больше `spinup_s` - `reset(t)`.
    pub fn step_to(&mut self, t: f64) {
        if self.nx == 0 {
            return;
        }
        let spin = self.cfg.spinup_s;
        if !self.started || t < self.time || t - self.time > spin {
            self.reset(t);
            return;
        }
        self.advance(t);
    }

    fn advance(&mut self, t: f64) {
        let dt = self.cfg.step_s.max(0.1);
        while self.time + dt <= t + 1.0e-6 {
            self.step(dt);
            self.time += dt;
        }
    }

    fn mark_towers(&mut self) {
        let n = self.nx * self.ny;
        self.tower.resize(n, 0);
        for c in 0..n {
            let u = f64::from(hash_v2i(c as i32, self.seed as i32) & 0xFFFF) / 65536.0;
            self.tower[c] = u8::from(u < self.overdev);
        }
    }

    fn step(&mut self, dt: f64) {
        let n = self.nx * self.ny;
        if n == 0 || !self.has_inputs {
            return;
        }
        let cfg = self.cfg.clone();
        self.adv_dt += dt;
        let ml =
            f64::from((self.mean_v[0] * self.mean_v[0] + self.mean_v[1] * self.mean_v[1]).sqrt());
        self.adv_disp += ml * dt;
        if self.adv_disp >= cfg.advect_cells * self.dx {
            self.advect(self.adv_dt);
            self.adv_disp = 0.0;
            self.adv_dt = 0.0;
        }
        let f = self.blend_frac();
        let blending = self.blend_s > 0.0 && f < 1.0;
        let ka = (dt / cfg.tau_form_s.max(dt)).min(1.0);
        let kl = dt / cfg.tau_life_s.max(dt);
        let tau_evap = cfg.tau_evap_s.max(dt);
        let inv_dref = 1.0 / cfg.evap_depth_ref_m.max(1.0);
        let kd = (dt / cfg.tau_deepen_s.max(dt)).min(1.0);
        let ko = (dt / cfg.tau_overdev_s.max(dt)).min(1.0);
        let inv_aref = 1.0 / cfg.overdev_ref_frac.max(1.0e-3);
        let tau_stage = cfg.tau_stage_s / dt;
        let q_floor = 0.02;
        let cover_min = cfg.cover_min;
        let depth_max = cfg.depth_max_m;
        let depth_day = self.depth_day;
        let mut sum_c = 0.0f64;
        let mut sum_cd = 0.0f64;
        for c in 0..n {
            let mut au = f64::from(self.au1[c]);
            let mut ds = f64::from(self.ds1[c]);
            if blending {
                let (a0, d0) = (f64::from(self.au0[c]), f64::from(self.ds0[c]));
                au = a0 + (au - a0) * f;
                ds = d0 + (ds - d0) * f;
            }
            let mut a = f64::from(self.a[c]);
            let mut p = f64::from(self.p[c]);
            let mut d = f64::from(self.d[c]);
            let mut od = f64::from(self.od[c]);
            let q0 = a + p;
            let ke = (dt / (tau_evap * clampf(d.max(100.0) * inv_dref, 0.5, 2.0))).min(1.0);
            p += a * kl - p * ke;
            a += (au - a) * ka;
            od += (au * inv_aref - od) * ko;
            let mut cap = depth_day;
            if self.tower[c] == 1 {
                cap += (depth_max - depth_day) * clampf(od, 0.0, 1.0);
            }
            if au > 0.0 {
                d += (ds.min(cap) - d) * kd;
            } else {
                d -= d * ke;
            }
            let q = a + p;
            let mut cov = q.min(1.0);
            if cov < cover_min {
                cov = 0.0;
            }
            self.cover[c] = cov as f32;
            self.a[c] = a as f32;
            self.p[c] = p as f32;
            self.d[c] = d as f32;
            self.od[c] = od as f32;
            if cov > 0.0 {
                self.depth[c] = d as f32;
                self.stage[c] = clampf((q - q0) * tau_stage / q.max(q_floor), -1.0, 1.0) as f32;
                self.activity[c] = clampf(a / q, 0.0, 1.0) as f32;
                sum_c += cov;
                sum_cd += cov * d;
            } else {
                self.depth[c] = 0.0;
                self.stage[c] = 0.0;
                self.activity[c] = 0.0;
            }
        }
        self.bg_cover = sum_c / n as f64;
        self.bg_depth = if sum_c > 0.0 { sum_cd / sum_c } else { 0.0 };
    }

    /// Полулагранжев перенос состояния за `tau` с.
    fn advect(&mut self, tau: f64) {
        let a0 = self.a.clone();
        let p0 = self.p.clone();
        let d0 = self.d.clone();
        let o0 = self.od.clone();
        let k = tau / self.dx;
        let (bgc, bgd) = (self.bg_cover, self.bg_depth);
        let (w, h) = (self.nx as i64, self.ny as i64);
        let (wm1, hm1) = (w - 1, h - 1);
        for j in 0..h {
            for i in 0..w {
                let c = (j * w + i) as usize;
                let ui = i as f64 - f64::from(self.vx[c]) * k;
                let uj = j as f64 + f64::from(self.vz[c]) * k;
                let i0 = ui.floor() as i64;
                let j0 = uj.floor() as i64;
                let fi = ui - i0 as f64;
                let fj = uj - j0 as f64;
                let w00 = (1.0 - fi) * (1.0 - fj);
                let w10 = fi * (1.0 - fj);
                let w01 = (1.0 - fi) * fj;
                let w11 = fi * fj;
                if i0 >= 0 && i0 < wm1 && j0 >= 0 && j0 < hm1 {
                    let s0 = (j0 * w + i0) as usize;
                    let s1 = s0 + w as usize;
                    let m = |x: &[f32]| {
                        (w00 * f64::from(x[s0])
                            + w10 * f64::from(x[s0 + 1])
                            + w01 * f64::from(x[s1])
                            + w11 * f64::from(x[s1 + 1])) as f32
                    };
                    self.a[c] = m(&a0);
                    self.p[c] = m(&p0);
                    self.d[c] = m(&d0);
                    self.od[c] = m(&o0);
                    continue;
                }
                let (mut sa, mut sp, mut sd, mut so) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
                for q in 0..4i64 {
                    let ii = i0 + (q & 1);
                    let jj = j0 + (q >> 1);
                    let wq = match q {
                        0 => w00,
                        1 => w10,
                        2 => w01,
                        _ => w11,
                    };
                    if wq <= 0.0 {
                        continue;
                    }
                    if ii >= 0 && ii < w && jj >= 0 && jj < h {
                        let s = (jj * w + ii) as usize;
                        sa += wq * f64::from(a0[s]);
                        sp += wq * f64::from(p0[s]);
                        sd += wq * f64::from(d0[s]);
                        so += wq * f64::from(o0[s]);
                    } else {
                        sp += wq * bgc;
                        sd += wq * bgd;
                    }
                }
                self.a[c] = sa as f32;
                self.p[c] = sp as f32;
                self.d[c] = sd as f32;
                self.od[c] = so as f32;
            }
        }
    }

    // ------------------------------------------------------------ выборка

    /// Индексы и веса: `[c00, c10, c01, c11]`, `fx`, `fy`.
    fn bilinear(&self, x: f64, z: f64) -> ([usize; 4], f64, f64) {
        let u = (x - self.x0) / self.dx - 0.5;
        let v = (-z - self.y0) / self.dx - 0.5;
        let i0 = (u.floor() as i64).clamp(0, self.nx as i64 - 1) as usize;
        let j0 = (v.floor() as i64).clamp(0, self.ny as i64 - 1) as usize;
        let i1 = (i0 + 1).min(self.nx - 1);
        let j1 = (j0 + 1).min(self.ny - 1);
        let fx = clampf(u - i0 as f64, 0.0, 1.0);
        let fy = clampf(v - j0 as f64, 0.0, 1.0);
        (
            [
                j0 * self.nx + i0,
                j0 * self.nx + i1,
                j1 * self.nx + i0,
                j1 * self.nx + i1,
            ],
            fx,
            fy,
        )
    }

    fn lerp4(arr: &[f32], b: &([usize; 4], f64, f64)) -> f64 {
        let (ix, fx, fy) = b;
        let g = |k: usize| f64::from(arr[ix[k]]);
        let top = g(0) + (g(1) - g(0)) * fx;
        let bot = g(2) + (g(3) - g(2)) * fx;
        top + (bot - top) * fy
    }

    fn edge_weight(&self, x: f64, z: f64) -> f64 {
        let fade = self.cfg.edge_fade_m.max(1.0);
        let ox = (self.x0 - x)
            .max(x - (self.x0 + self.nx as f64 * self.dx))
            .max(0.0);
        let y = -z;
        let oy = (self.y0 - y)
            .max(y - (self.y0 + self.ny as f64 * self.dx))
            .max(0.0);
        let dist = (ox * ox + oy * oy).sqrt();
        clampf(1.0 - dist / fade, 0.0, 1.0)
    }

    /// `(cover, base_msl, base_msl + depth, stage)` билинейно; вне сетки - фон (`Vector4`: f32).
    pub fn sample(&self, p: [f32; 3]) -> [f32; 4] {
        if self.nx == 0 {
            return [
                self.bg_cover as f32,
                self.base_msl as f32,
                (self.base_msl + self.bg_depth) as f32,
                0.0,
            ];
        }
        let (x, z) = (f64::from(p[0]), f64::from(p[2]));
        let b = self.bilinear(x, z);
        let w = self.edge_weight(x, z);
        let mut c = Self::lerp4(&self.cover, &b);
        let mut d = Self::lerp4(&self.depth, &b);
        let mut s = Self::lerp4(&self.stage, &b);
        c = self.bg_cover + (c - self.bg_cover) * w;
        d = self.bg_depth + (d - self.bg_depth) * w;
        s *= w;
        [
            c as f32,
            self.base_msl as f32,
            (self.base_msl + d) as f32,
            s as f32,
        ]
    }

    /// Грубая плотность 0..1 без шума: покрытие × вертикальный профиль.
    pub fn density_at(&self, p: [f32; 3]) -> f64 {
        let s = self.sample(p);
        let d = f64::from(s[2]) - f64::from(s[1]);
        let y = f64::from(p[1]);
        if s[0] <= 0.0 || d <= 0.0 || y < f64::from(s[1]) || y > f64::from(s[2]) {
            return 0.0;
        }
        let zeta = (y - f64::from(s[1])) / d;
        f64::from(s[0]) * clampf(6.0 * zeta * (1.0 - zeta), 0.0, 1.0)
    }

    /// Доля прямого солнца, закрытая полем над точкой земли `(x, z)`.
    pub fn shade_at(&self, xz: [f32; 2], sun: [f32; 3]) -> f64 {
        if self.nx == 0 || sun[1] <= 0.05 {
            return 0.0;
        }
        let mut h = self.base_msl - 1000.0;
        if self.hc.len() == self.nx * self.ny && self.nx > 0 {
            h = Self::lerp4(&self.hc, &self.bilinear(f64::from(xz[0]), f64::from(xz[1])));
        }
        let dz = (self.base_msl - h).max(0.0);
        let off = dz / f64::from(sun[1]);
        let s = self.sample([
            (f64::from(xz[0]) + f64::from(sun[0]) * off) as f32,
            self.base_msl as f32,
            (f64::from(xz[1]) + f64::from(sun[2]) * off) as f32,
        ]);
        let d = f64::from(s[2]) - f64::from(s[1]);
        if s[0] <= 0.0 || d <= 0.0 {
            return 0.0;
        }
        f64::from(s[0]) * (1.0 - (-d / self.cfg.shade_depth_m.max(1.0)).exp())
    }
}
