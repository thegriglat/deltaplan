//! Облака в физике: подсос, плотность, поток в облаке, видимые облака.
//! Кучево-дождевые (Cb) - облака-объекты (`CloudModel`), кучевые - поле [`CloudField`].
//!
//! Снимок [`CloudPhysics`] неизменяем; обновляет его [`CloudSlot`](super::CloudSlot). Шаг поля в
//! Эталон идёт в рабочем потоке; в крейте он синхронный внутри `Terms::advance` (один шаг 20 с -
//! доли миллисекунды, разгон `start_at` - 120 шагов).
use super::cfg::PhysCfg;
use super::field::CloudField;
use crate::terms::WeatherView;
use crate::terms::storm::CloudModel;
use crate::terms::thermal::life::smoothstep;
use crate::terms::thermal::{AtmoThermal, CloudHooks};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

/// Меньше этого подсоса нет.
const MIN_K: f64 = 0.02;

/// Облако-объект рядом: `[cx, cz, кромка, мощность, rx, rz, плотность, ax.x, ax.z]`.
type Rec = [f32; 9];

#[derive(Default)]
pub struct Objects {
    grid: HashMap<(i64, i64), Vec<usize>>,
    recs: Vec<Rec>,
    cell: f64,
    y_min: f64,
    y_max: f64,
    pub count: usize,
}

impl Objects {
    pub fn empty() -> Self {
        Objects {
            cell: 1800.0,
            y_min: 1.0e9,
            y_max: -1.0e9,
            ..Default::default()
        }
    }
}

/// Облако поля, видимое наблюдателю.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VisibleCloud {
    pub center: [f64; 2],
    pub radius: f64,
    pub growth: f64,
    pub decay: f64,
}

#[derive(Clone)]
pub struct CloudPhysics {
    pub cfg: Arc<PhysCfg>,
    pub model: CloudModel,
    pub field: Arc<CloudField>,
    pub objects: Arc<Objects>,
    /// Столбцов поля с облаком (≥ 0,05) в радиусе физики у фокуса.
    pub field_count: usize,
    /// Растёт при каждой смене поля.
    pub version: u64,
    raster: Arc<OnceLock<Arc<crate::Raster>>>,
}

fn f32len(x: f64, y: f64) -> f64 {
    let (x, y) = (x as f32, y as f32);
    f64::from((x * x + y * y).sqrt())
}

impl CloudPhysics {
    pub fn new(cfg: Arc<PhysCfg>, model: CloudModel, field: Arc<CloudField>) -> Self {
        CloudPhysics {
            cfg,
            model,
            field,
            objects: Arc::new(Objects::empty()),
            field_count: 0,
            version: 0,
            raster: Arc::new(OnceLock::new()),
        }
    }

    /// Пересобрать растр-кеш при смене поля.
    pub fn set_field(&mut self, field: Arc<CloudField>, count: usize) {
        self.field = field;
        self.field_count = count;
        self.version += 1;
        self.raster = Arc::new(OnceLock::new());
    }

    pub fn raster_cache(&self) -> &OnceLock<Arc<crate::Raster>> {
        &self.raster
    }

    /// Поле облачности есть.
    pub fn has_field(&self) -> bool {
        self.field.nx != 0
    }

    pub fn cloud_count(&self) -> usize {
        self.objects.count + self.field_count
    }

    /// Подсос термика в момент `t`: `[усиление подъёма у основания, высота потока в облаке, м]`.
    pub fn suck(&self, th: &AtmoThermal, t: f64) -> [f64; 2] {
        let r = if th.has_cloud {
            self.suck_object(th, t)
        } else {
            self.suck_field(th, t)
        };
        [f64::from(r[0] as f32), f64::from(r[1] as f32)]
    }

    fn suck_object(&self, th: &AtmoThermal, t: f64) -> [f64; 2] {
        let st = self.model.stage(th, t);
        if st[0] < 0.0 {
            return [th.suck, 0.0];
        }
        let sz = self.model.size(th, st);
        let c = &*self.cfg;
        let diam = 2.0 * sz[0].min(sz[1]);
        let mut k = smoothstep(c.size_min, c.size_full, diam) * smoothstep(0.3, 0.8, st[0]);
        k *= 1.0 - smoothstep(0.0, 0.35, st[1]);
        k *= st[2];
        if k < MIN_K {
            return [th.suck, 0.0];
        }
        [c.suck_boost * k + th.suck, sz[2] * c.in_cloud_frac * k]
    }

    fn suck_field(&self, th: &AtmoThermal, t: f64) -> [f64; 2] {
        let f = &*self.field;
        if f.nx == 0 || th.top < f.base_msl - 50.0 {
            return [th.suck, 0.0];
        }
        let dr = th.phase(t).drift;
        let ax = th.axis_at(f.base_msl, dr);
        let (cx, cz) = (ax[0] as f32, ax[1] as f32);
        let s = f.sample([cx, f.base_msl as f32, cz]);
        if s[0] <= 0.0 {
            return [th.suck, 0.0];
        }
        let sz = self.model.size(th, [1.0, 0.0, 1.0]);
        let c = &*self.cfg;
        let diam = 2.0 * sz[0].min(sz[1]);
        let sw = f64::from(s[3]);
        let mut k =
            smoothstep(c.size_min, c.size_full, diam) * smoothstep(0.0, 0.1, f64::from(s[0]));
        k *= smoothstep(0.3, 0.8, 1.0 - sw.max(0.0));
        k *= 1.0 - smoothstep(0.0, 0.35, (-sw).max(0.0));
        k *= activity_at(f, f64::from(cx), f64::from(cz));
        if k < MIN_K {
            return [th.suck, 0.0];
        }
        [
            c.suck_boost * k + th.suck,
            (f64::from(s[2]) - f64::from(s[1])) * c.in_cloud_frac * k,
        ]
    }

    /// Cb-объекты рядом с фокусом на момент `t` (`_refresh_objects`).
    pub fn build_objects(
        &self,
        all: &[Arc<AtmoThermal>],
        t: f64,
        focus: Option<[f32; 3]>,
        radius: f64,
    ) -> Objects {
        let cell = self.cfg.cell;
        let mut o = Objects {
            cell,
            y_min: 1.0e9,
            y_max: -1.0e9,
            ..Default::default()
        };
        let r2 = radius * radius;
        for th in all {
            if !th.has_cloud {
                continue;
            }
            let st = self.model.stage(th, t);
            if st[0] < 0.0 {
                continue;
            }
            let c = self.model.center(th, t);
            if let Some(fp) = focus {
                let (dx, dz) = (
                    f64::from(fp[0]) - f64::from(c[0]),
                    f64::from(fp[2]) - f64::from(c[1]),
                );
                if dx * dx + dz * dz > r2 {
                    continue;
                }
            }
            let sz = self.model.size(th, st);
            let dens = st[0] * (1.0 - st[1] * st[1]);
            let (vx, vz) = (th.drift_vel[0], th.drift_vel[1]);
            let l2 = vx * vx + vz * vz;
            let ax = if f64::from(l2) > 1.0e-6 {
                let l = l2.sqrt();
                [vx / l, vz / l]
            } else {
                [1.0, 0.0]
            };
            let rec: Rec = [
                c[0],
                c[1],
                th.top as f32,
                sz[2] as f32,
                sz[0] as f32,
                sz[1] as f32,
                dens as f32,
                ax[0],
                ax[1],
            ];
            let rmax = sz[0].max(sz[1]);
            o.y_min = o.y_min.min(th.top);
            o.y_max = o.y_max.max(th.top + sz[2]);
            let idx = o.recs.len();
            o.recs.push(rec);
            let (cx, cz) = (f64::from(c[0]), f64::from(c[1]));
            let g = |v: f64| (v / cell).floor() as i64;
            for gz in g(cz - rmax)..=g(cz + rmax) {
                for gx in g(cx - rmax)..=g(cx + rmax) {
                    o.grid.entry((gx, gz)).or_default().push(idx);
                }
            }
            o.count += 1;
        }
        o
    }

    /// Столбцов поля с облаком ≥ 0,05 в круге `radius` у фокуса.
    pub fn count_field(f: &CloudField, focus: Option<[f32; 3]>, radius: f64) -> usize {
        let r2 = radius * radius;
        let mut n = 0;
        for j in 0..f.ny {
            let z = -(f.y0 + (j as f64 + 0.5) * f.dx);
            let (fx, fz) = focus.map_or((0.0, 0.0), |p| (f64::from(p[0]), f64::from(p[2])));
            let dz = z - fz;
            for i in 0..f.nx {
                if f.cover[j * f.nx + i] >= 0.05 {
                    let dxx = f.x0 + (i as f64 + 0.5) * f.dx - fx;
                    if dxx * dxx + dz * dz <= r2 {
                        n += 1;
                    }
                }
            }
        }
        n
    }

    fn sample_objects(&self, pos: [f32; 3]) -> [f32; 3] {
        let o = &*self.objects;
        let y = f64::from(pos[1]);
        if y < o.y_min || y > o.y_max {
            return [0.0; 3];
        }
        let key = (
            (f64::from(pos[0]) / o.cell).floor() as i64,
            (f64::from(pos[2]) / o.cell).floor() as i64,
        );
        let Some(list) = o.grid.get(&key) else {
            return [0.0; 3];
        };
        let mut best = [0.0f32; 3];
        for &ri in list {
            let rec = &o.recs[ri];
            let r = |k: usize| f64::from(rec[k]);
            let hn = (y - r(2)) / r(3);
            if !(0.0..=1.0).contains(&hn) {
                continue;
            }
            let dx = f64::from(pos[0]) - r(0);
            let dz = f64::from(pos[2]) - r(1);
            let u = (dx * r(7) + dz * r(8)) / r(4);
            let v = (-dx * r(8) + dz * r(7)) / r(5);
            let q = 1.0 - f32len((u * u + v * v).sqrt() / 0.85, hn);
            if q > 0.0 {
                let d = smoothstep(0.0, 0.15, q) * r(6);
                if d > f64::from(best[0]) {
                    let rr = (dx * dx + dz * dz).sqrt();
                    best = if rr > 1.0 {
                        [d as f32, (dx / rr) as f32, (dz / rr) as f32]
                    } else {
                        [d as f32, 1.0, 0.0]
                    };
                }
            }
        }
        best
    }

    /// Плотность облака в точке 0..1 (`density_at`).
    pub fn density_at(&self, pos: [f32; 3]) -> f64 {
        let mut d = f64::from(self.sample_objects(pos)[0]);
        let f = &*self.field;
        let y = f64::from(pos[1]);
        if f.nx != 0 && y >= f.base_msl && y <= f.base_msl + self.cfg.depth_max {
            d = d.max(f.density_at(pos));
        }
        d
    }

    /// `[плотность 0..1, направление к краю x, z]` - в облаке поток «выкидывает» к краю.
    pub fn sample(&self, pos: [f32; 3]) -> [f32; 3] {
        let mut best = self.sample_objects(pos);
        let f = &*self.field;
        let y = f64::from(pos[1]);
        if f.nx != 0 && y >= f.base_msl && y <= f.base_msl + self.cfg.depth_max {
            let d = f.density_at(pos);
            if d > f64::from(best[0]) {
                let e = (1.5 * f.dx) as f32;
                let cv =
                    |dx: f32, dz: f32| f64::from(f.sample([pos[0] + dx, pos[1], pos[2] + dz])[0]);
                let gx = cv(e, 0.0) - cv(-e, 0.0);
                let gz = cv(0.0, e) - cv(0.0, -e);
                let g = (gx * gx + gz * gz).sqrt();
                best = if g > 1.0e-5 {
                    [d as f32, (-gx / g) as f32, (-gz / g) as f32]
                } else {
                    [d as f32, 0.0, 0.0]
                };
            }
        }
        best
    }

    /// Облака поля над термиками рядом, по одному на столбец.
    pub fn visible_clouds(
        &self,
        all: &[Arc<AtmoThermal>],
        t: f64,
        focus: [f32; 3],
    ) -> Vec<VisibleCloud> {
        let mut out = Vec::new();
        let f = &*self.field;
        if f.nx == 0 {
            return out;
        }
        let far = self.cfg.max_distance_m;
        let mut ids: Vec<&Arc<AtmoThermal>> = all.iter().collect();
        ids.sort_by_key(|a| a.id);
        let mut seen: std::collections::HashSet<(i64, i64)> = Default::default();
        for th in ids {
            if th.is_cb || th.top < f.base_msl - 50.0 {
                continue;
            }
            let ax = th.axis_at(f.base_msl, th.phase(t).drift);
            let c = [f64::from(ax[0] as f32), f64::from(ax[1] as f32)];
            let dist = (f64::from(focus[0]) - c[0]).hypot(f64::from(focus[2]) - c[1]);
            if dist > far {
                continue;
            }
            let s = f.sample([c[0] as f32, f.base_msl as f32, c[1] as f32]);
            if f64::from(s[0]) < self.cfg.cover_min {
                continue;
            }
            let key = (
                ((c[0] - f.x0) / f.dx).floor() as i64,
                ((-c[1] - f.y0) / f.dx).floor() as i64,
            );
            if !seen.insert(key) {
                continue;
            }
            let depth = f64::from(s[2]) - f64::from(s[1]);
            out.push(VisibleCloud {
                center: c,
                radius: (0.5 * depth / self.cfg.hw).max(0.5 * f.dx * f64::from(s[0]).sqrt()),
                growth: smoothstep(0.0, 0.5, f64::from(s[3])),
                decay: f64::from(-s[3]).max(0.0),
            });
        }
        out
    }
}

/// Активность поля (0..1) в столбце над `(x, z)`.
pub fn activity_at(f: &CloudField, x: f64, z: f64) -> f64 {
    let i = ((x - f.x0) / f.dx).floor() as i64;
    let j = ((-z - f.y0) / f.dx).floor() as i64;
    if i < 0 || i >= f.nx as i64 || j < 0 || j >= f.ny as i64 {
        return 0.0;
    }
    f64::from(f.activity[j as usize * f.nx + i as usize])
}

impl CloudHooks for CloudPhysics {
    fn shade_at(&self, x: f64, z: f64, sun: [f64; 3]) -> f64 {
        self.field.shade_at(
            [x as f32, z as f32],
            [sun[0] as f32, sun[1] as f32, sun[2] as f32],
        )
    }
    fn suck(&self, th: &AtmoThermal, t: f64) -> [f64; 2] {
        CloudPhysics::suck(self, th, t)
    }
}

/// `cloud_size_factor` погоды (множитель размера облаков).
pub fn size_factor(w: &WeatherView) -> f64 {
    w.f64_or("cloud_size_factor", 1.0)
}
