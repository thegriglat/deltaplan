//! Слагаемое `cloud` (RW-11d): поле облачности ([`CloudField`]), его входы ([`prepare`]) и физика
//! облаков ([`CloudPhysics`]: подсос, плотность, `sample`, `visible_clouds`, `shade_at`), описания
//! W6 `cloud_raster`, `clouds` и `cloud_density_many` (pub-функции).
//!
//! ## Состояние во времени
//! Слот [`CloudSlot`] (`Slots::clouds`) держит неизменяемый снимок [`CloudPhysics`]. Его обновляет
//! `Terms::advance(t)`: Cb-объекты - при сдвиге времени на `OBJECTS_REFRESH_S` (0,1 с), поле -
//! раз в `step_s` (20 с) на сетке шагов, `Terms::start_at(t)` - разгон поля 2400 с от пустого.
//! Входы поля даёт [`CloudInputs`]: по умолчанию [`AnalyticInputs`] (живые термики слота
//! `thermal`, кромка из его `Setup`); путь «поле воздуха» (`Field` + `AirThermals`) подключает
//! RW-10e/RW-12z через `Terms::set_cloud_inputs`.
//!
//! ## Крючки RW-10f
//! `CloudPhysics` реализует [`CloudHooks`](super::thermal::CloudHooks) (`suck`, `shade_at`):
//! `Arc<CloudPhysics>` берётся из `Terms::cloud_physics()` и отдаётся слоту термиков.
//!
//! ## Границы модели
//! - Бурление в облаке (`chaos_noise`, `gust_unit` ветровой рамки) в крейте пока нет (RW-9):
//!   нули; σ бурления и поток к краю считаются.
//! - Шаг поля синхронный (в GD - рабочий поток); сеть (снимок К4) и текстура К2 не переносятся.
//! - Облака-объекты строятся на момент последнего обновления, как `_refresh_objects`.
pub mod cfg;
pub mod field;
pub mod physics;
pub mod sources;

pub use cfg::{FieldCfg, PhysCfg};
pub use field::{CloudField, FieldInputs};
pub use physics::{CloudPhysics, VisibleCloud, activity_at};
pub use sources::{Grid, ThermalSnap, penetration, prepare, snapshot_thermals, z_i_at};

use super::Terms;
use super::slots::{Extra, ExtraOut};
use super::storm::{CloudCfg, CloudModel};
use crate::{Cloud, Configs, Raster};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

/// Период обновления Cb-объектов, с атмосферы.
pub const OBJECTS_REFRESH_S: f64 = 0.1;

/// Поставщик входов поля облаков.
pub trait CloudInputs: Send + Sync {
    /// Дешёвый ключ входов: смена - входы пересобираются (`CloudPhysics._key_of`). `None` - поле
    /// не считается.
    fn key(&self, terms: &Terms) -> Option<u64>;
    /// Входы на момент `t` (сетка шагов).
    fn inputs(&self, terms: &Terms, t: f64) -> Option<FieldInputs>;
}

/// Аналитический путь: живые термики слота `thermal`, кромка - из его `Setup`.
pub struct AnalyticInputs;

impl CloudInputs for AnalyticInputs {
    fn key(&self, terms: &Terms) -> Option<u64> {
        let setup = terms.slots.thermal.as_slot()?.setup()?;
        let mut h = DefaultHasher::new();
        setup.cloudbase_msl.to_bits().hash(&mut h);
        serde_json::to_string(terms.weather.map())
            .ok()?
            .hash(&mut h);
        Some(h.finish())
    }

    fn inputs(&self, terms: &Terms, t: f64) -> Option<FieldInputs> {
        let slot = terms.slots.thermal.as_slot()?;
        let setup = slot.setup()?;
        let all = &slot.state()?.all;
        let ground_ref = setup.cloudbase_msl - terms.weather.f64_or("cloudbase_agl_m", 0.0);
        let wind = terms.wind.clone();
        Some(FieldInputs {
            grid: Grid::default_domain(),
            wind_field: None,
            air: None,
            thermals: Some(snapshot_thermals(all, t)),
            weather: terms.weather.clone(),
            cloudbase_msl: Some(setup.cloudbase_msl),
            ground_ref: Some(ground_ref),
            seed: terms.seed as i64,
            wind_at: Arc::new(move |z| wind.vec2_at((z - ground_ref).max(0.0))),
        })
    }
}

/// Слот облаков: снимок физики и обновление.
#[derive(Clone)]
pub struct CloudSlot {
    inputs: Option<Arc<dyn CloudInputs>>,
    phys: Arc<CloudPhysics>,
    fcfg: FieldCfg,
    ccfg: CloudCfg,
    cfg_ptr: usize,
    key: Option<u64>,
    last_obj_t: f64,
}

impl CloudSlot {
    pub fn new(inputs: Option<Arc<dyn CloudInputs>>) -> Self {
        let fcfg = FieldCfg::default();
        let phys = CloudPhysics::new(
            Arc::new(PhysCfg::default()),
            CloudModel::new(CloudCfg::default(), 1.0),
            Arc::new(CloudField::new(fcfg.clone())),
        );
        CloudSlot {
            inputs,
            phys: Arc::new(phys),
            fcfg,
            ccfg: CloudCfg::default(),
            cfg_ptr: 0,
            key: None,
            last_obj_t: f64::NEG_INFINITY,
        }
    }

    /// Слот с аналитическими входами (по умолчанию).
    pub fn analytic() -> Self {
        Self::new(Some(Arc::new(AnalyticInputs)))
    }

    pub fn with_inputs(&self, inputs: Arc<dyn CloudInputs>) -> Self {
        let mut s = CloudSlot::new(Some(inputs));
        s.cfg_ptr = 0;
        s
    }

    pub fn physics(&self) -> &Arc<CloudPhysics> {
        &self.phys
    }

    /// Новый снимок на момент `t` или `None` - прежний годится. `force` - `start_at`.
    pub fn advanced(&self, terms: &Terms, t: f64, force: bool) -> Option<Arc<CloudSlot>> {
        let mut s = self.clone();
        let mut phys = (*self.phys).clone();
        let mut changed = false;
        let ptr = Arc::as_ptr(&terms.configs) as usize;
        if ptr != self.cfg_ptr {
            s.cfg_ptr = ptr;
            s.fcfg = FieldCfg::from_configs(&terms.configs);
            s.ccfg = CloudCfg::from_configs(&terms.configs);
            phys.cfg = Arc::new(PhysCfg::from_configs(&terms.configs));
            phys.set_field(Arc::new(CloudField::new(s.fcfg.clone())), 0);
            s.key = None;
            s.last_obj_t = f64::NEG_INFINITY;
            changed = true;
        }
        phys.model = CloudModel::new(s.ccfg, super::clouds::physics::size_factor(&terms.weather));
        let obj_due = force || t < s.last_obj_t || t - s.last_obj_t >= OBJECTS_REFRESH_S;
        let step = s.fcfg.step_s.max(0.1);
        let tq = (t / step + 1.0e-9).floor() * step;
        let field_due =
            phys.field.nx == 0 || tq < phys.field.time || tq - phys.field.time >= step - 1.0e-6;
        if !(changed || obj_due || field_due) {
            return None;
        }
        let focus = terms.focuses.first().map(|f| f.pos);
        let radius = phys.cfg.physics_radius_m;
        let all: &[Arc<crate::terms::thermal::AtmoThermal>] = terms
            .slots
            .thermal
            .as_slot()
            .and_then(|sl| sl.state())
            .map_or(&[], |st| &st.all[..]);
        if s.fcfg.enabled
            && let Some(prov) = s.inputs.clone()
            && (force || changed || field_due || obj_due)
            && let Some(key) = prov.key(terms)
        {
            let key_changed = s.key != Some(key);
            if (force || key_changed || field_due)
                && let Some(inp) = prov.inputs(terms, tq)
            {
                let mut f = (*phys.field).clone();
                if force {
                    f.invalidate();
                }
                if key_changed || inp.air.is_none() || f.nx == 0 {
                    f.set_inputs(&inp);
                }
                f.step_to(tq);
                let n = CloudPhysics::count_field(&f, focus, radius);
                phys.set_field(Arc::new(f), n);
                s.key = Some(key);
            }
        }
        if obj_due || changed {
            phys.objects = Arc::new(phys.build_objects(all, t, focus, radius));
            s.last_obj_t = t;
        }
        s.phys = Arc::new(phys);
        Some(Arc::new(s))
    }
}

/// Часть слота `Extra`: слагаемое `cloud` и бурление в облаке.
#[derive(Default)]
pub struct CloudExtra;

impl CloudExtra {
    pub fn new() -> Self {
        CloudExtra
    }
}

impl Extra for CloudExtra {
    fn flow(&self, c: &super::Ctx, _v: [f64; 3]) -> Option<ExtraOut> {
        let ph = c.terms.clouds.physics();
        if ph.cloud_count() == 0 {
            return None;
        }
        let s = ph.sample(c.pos);
        if s[0] <= 0.0 {
            return None;
        }
        let eject = ph.cfg.in_cloud_eject_ms as f32;
        let q = |x: f32| f64::from(x);
        Some(ExtraOut {
            cloud: [q(s[1] * eject * s[0]), 0.0, q(s[2] * eject * s[0])],
            chaos: ph.cfg.in_cloud_ms * f64::from(s[0]),
            ..ExtraOut::default()
        })
    }
}

/// Облака поля и Cb для описания W6 `clouds` на момент `t` (шаг `CLOUD_STRIDE = 10`).
pub fn clouds(terms: &Terms, center: [f32; 3], radius: f32, t: f64, out: &mut Vec<Cloud>) {
    out.clear();
    let ph = terms.clouds.physics();
    let all: &[Arc<crate::terms::thermal::AtmoThermal>] = terms
        .slots
        .thermal
        .as_slot()
        .and_then(|sl| sl.state())
        .map_or(&[], |st| &st.all[..]);
    let c2 = [f64::from(center[0]), f64::from(center[2])];
    let dist = |a: [f64; 2]| (c2[0] - a[0]).hypot(c2[1] - a[1]);
    let radius = f64::from(radius);
    let focus = terms.focuses.first().map_or([0.0; 3], |f| f.pos);
    let mut sorted: Vec<&Arc<crate::terms::thermal::AtmoThermal>> = all.iter().collect();
    sorted.sort_by_key(|a| a.id);
    let f = &*ph.field;
    let mut cid = 0.0f32;
    if f.nx > 0 {
        for cl in ph.visible_clouds(all, t, focus) {
            if dist(cl.center) > radius {
                continue;
            }
            let cc = cl.center;
            let s = f.sample([cc[0] as f32, f.base_msl as f32, cc[1] as f32]);
            let mut core_id = -1.0f32;
            for th in &sorted {
                if th.is_cb {
                    continue;
                }
                let ax = th.axis_at(f.base_msl, th.phase(t).drift);
                if f64::from(ax[0] as f32) == cc[0] && f64::from(ax[1] as f32) == cc[1] {
                    core_id = (th.id & 0xFFFFFF) as f32;
                    break;
                }
            }
            cid += 1.0;
            out.push(Cloud {
                id: cid,
                core_id,
                x: cc[0] as f32,
                z: cc[1] as f32,
                base_msl: s[1],
                top_msl: s[2],
                radius: cl.radius as f32,
                growth: cl.growth as f32,
                decay: cl.decay as f32,
                flags: 0.0,
            });
        }
    }
    for th in &sorted {
        if !th.is_cb {
            continue;
        }
        let st = ph.model.stage(th, t);
        if st[0] < 0.0 {
            continue;
        }
        let c3 = ph.model.center(th, t);
        if dist([f64::from(c3[0]), f64::from(c3[1])]) > radius {
            continue;
        }
        let sz = ph.model.size(th, st);
        out.push(Cloud {
            id: ((100000 + th.id) & 0xFFFFFF) as f32,
            core_id: (th.id & 0xFFFFFF) as f32,
            x: c3[0],
            z: c3[1],
            base_msl: th.top as f32,
            top_msl: (th.top + sz[2]) as f32,
            radius: sz[0].max(sz[1]) as f32,
            growth: st[0] as f32,
            decay: st[1] as f32,
            flags: 4.0,
        });
    }
}

/// Плотность облака в точках (`cloud_density_many`); не конечная точка - 0.
pub fn cloud_density_many(terms: &Terms, pts: &[[f32; 3]], out: &mut [f32]) {
    let ph = terms.clouds.physics();
    for (o, p) in out.iter_mut().zip(pts) {
        *o = 0.0;
        if p.iter().all(|v| v.is_finite()) {
            let d = ph.density_at(*p);
            if d.is_finite() {
                *o = d as f32;
            }
        }
    }
}

/// Растр поля облаков на сетке W1: узлы - центры столбцов, строка растёт к +Z. `None` - поля нет.
pub fn cloud_raster(terms: &Terms) -> Option<Arc<Raster>> {
    let ph = terms.clouds.physics();
    let f = &*ph.field;
    if f.nx == 0 {
        return None;
    }
    Some(
        ph.raster_cache()
            .get_or_init(|| {
                let (nx, ny) = (f.nx, f.ny);
                let flip = |a: &[f32]| {
                    let mut o = Vec::with_capacity(nx * ny);
                    for j in (0..ny).rev() {
                        o.extend_from_slice(&a[j * nx..(j + 1) * nx]);
                    }
                    o
                };
                let n = nx * ny;
                Arc::new(Raster {
                    version: ph.version,
                    nx: nx as u32,
                    ny: ny as u32,
                    dx: f.dx as f32,
                    x0: (f.x0 + 0.5 * f.dx) as f32,
                    z0: (-(f.y0 + (ny as f64 - 0.5) * f.dx)) as f32,
                    base_msl: f.base_msl as f32,
                    time_s: f.time,
                    layers: vec![
                        ("cover".into(), flip(&f.cover)),
                        ("depth".into(), flip(&f.depth)),
                        ("stage".into(), flip(&f.stage)),
                        ("activity".into(), flip(&f.activity)),
                        ("bg_cover".into(), vec![f.bg_cover as f32; n]),
                        ("bg_depth".into(), vec![f.bg_depth as f32; n]),
                    ],
                })
            })
            .clone(),
    )
}

/// Конфиги облаков для тестов.
pub fn cfgs(c: &Configs) -> (FieldCfg, PhysCfg, CloudCfg) {
    (
        FieldCfg::from_configs(c),
        PhysCfg::from_configs(c),
        CloudCfg::from_configs(c),
    )
}
