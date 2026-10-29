//! Набор термиков вокруг фокуса и опрос (`ThermalField.sample`): сетка быстрого поиска (бакеты
//! `bucket_m`, в каждый вписана капсула оси термика с запасом на снос), результат
//! `(w, маска, σ края)`; ядра в радиусе физики вокруг фокуса — «активные».
use super::CloudHooks;
use super::cells::Setup;
use super::life::AtmoThermal;
use super::profile::{Edge, contribution};
use std::collections::HashMap;
use std::sync::Arc;

/// Набор термиков на момент обновления `t` (раз в `refresh_interval_s` атмосферы).
pub struct State {
    pub t: f64,
    /// Запас на снос между обновлениями, с.
    pub margin: f64,
    /// Фокусы: действует на воздух и отдаётся в `cores` то, что ближе радиуса физики к любому.
    pub focuses: Vec<[f64; 2]>,
    /// Номер ячейки обновления: `floor(t / dt)`.
    pub slot: i64,
    /// Все живые на `t` (динамические и статичные).
    pub all: Vec<Arc<AtmoThermal>>,
    /// Термики в радиусе физики вокруг фокуса — те, что действуют на воздух и попадают в `cores`.
    pub active: Vec<Arc<AtmoThermal>>,
    buckets: HashMap<(i64, i64), Vec<u32>>,
    inv_bucket: f64,
}

impl State {
    /// Пустой снимок с номером ячейки обновления (для фоновой задачи: нужен только `slot`).
    pub fn stub(slot: i64) -> State {
        State {
            t: 0.0,
            margin: 0.0,
            focuses: Vec::new(),
            slot,
            all: Vec::new(),
            active: Vec::new(),
            buckets: HashMap::new(),
            inv_bucket: 1.0,
        }
    }

    /// `begin_refresh` + `step_refresh`: сетка поиска по живым `all` на момент `t`.
    pub fn build(
        setup: &Setup,
        all: Vec<Arc<AtmoThermal>>,
        t: f64,
        focuses: &[[f64; 2]],
        margin: f64,
        slot: i64,
    ) -> State {
        let cfg = &setup.cfg;
        let bucket = cfg.bucket_m;
        let mut st = State {
            t,
            margin,
            focuses: focuses.to_vec(),
            slot,
            all,
            active: Vec::new(),
            buckets: HashMap::new(),
            inv_bucket: 1.0 / bucket,
        };
        let cut = cfg.profile_cutoff_radii;
        for th in st.all.clone() {
            if !(th.is_static || t <= th.t_end()) {
                continue;
            }
            let ph = th.phase(t);
            let p0 = th.axis_at(f64::from(th.src[1]), ph.drift);
            // поток продолжается внутрь облака (подсос): столб до верха облака
            let mut p1 = th.axis_at(th.top + th.cloud_depth, ph.drift);
            let dv = [f64::from(th.drift_vel[0]), f64::from(th.drift_vel[1])];
            let pad = th.radius * cut + dv[0].hypot(dv[1]) * margin;
            if !th.is_static && t + margin > th.drift_start() {
                p1[0] += dv[0] * margin;
                p1[1] += dv[1] * margin;
            }
            let mid = [(p0[0] + p1[0]) * 0.5, (p0[1] + p1[1]) * 0.5];
            let half = (p0[0] - p1[0]).hypot(p0[1] - p1[1]) * 0.5;
            let near = focuses
                .iter()
                .any(|f| (f[0] - mid[0]).hypot(f[1] - mid[1]) - half - pad <= cfg.physics_radius_m);
            if near {
                let off = st.active.len() as u32;
                st.active.push(th.clone());
                st.insert_capsule(p0, p1, pad, off, bucket);
            }
        }
        st
    }

    /// Вписать отрезок `p0–p1` с запасом `pad` в ячейки поиска: по строкам z находим диапазон x.
    fn insert_capsule(&mut self, p0: [f64; 2], p1: [f64; 2], pad: f64, off: u32, bucket: f64) {
        let inv = self.inv_bucket;
        let bz0 = ((p0[1].min(p1[1]) - pad) * inv).floor() as i64;
        let bz1 = ((p0[1].max(p1[1]) + pad) * inv).floor() as i64;
        let dz = p1[1] - p0[1];
        for bz in bz0..=bz1 {
            let z_lo = bz as f64 * bucket - pad;
            let z_hi = (bz + 1) as f64 * bucket + pad;
            let (mut ta, mut tb) = (0.0f64, 1.0f64);
            if dz.abs() > 1.0e-6 {
                let t1 = (z_lo - p0[1]) / dz;
                let t2 = (z_hi - p0[1]) / dz;
                ta = t1.min(t2).clamp(0.0, 1.0);
                tb = t1.max(t2).clamp(0.0, 1.0);
            }
            let xa = p0[0] + (p1[0] - p0[0]) * ta;
            let xb = p0[0] + (p1[0] - p0[0]) * tb;
            let bx0 = ((xa.min(xb) - pad) * inv).floor() as i64;
            let bx1 = ((xa.max(xb) + pad) * inv).floor() as i64;
            for bx in bx0..=bx1 {
                self.buckets.entry((bx, bz)).or_default().push(off);
            }
        }
    }

    /// Вертикальный поток от термиков в точке `pos` в момент `t`: `(w, маска ядра, σ края)`.
    pub fn sample(&self, setup: &Setup, hooks: &dyn CloudHooks, pos: [f32; 3], t: f64) -> [f64; 3] {
        let key = (
            (f64::from(pos[0]) * self.inv_bucket).floor() as i64,
            (f64::from(pos[2]) * self.inv_bucket).floor() as i64,
        );
        let Some(list) = self.buckets.get(&key) else {
            return [0.0; 3];
        };
        let edge = Edge {
            k: setup.edge_k,
            w: setup.edge_w,
        };
        let (mut w, mut mask, mut edge2) = (0.0f64, 0.0f64, 0.0f64);
        for &o in list {
            let th = &self.active[o as usize];
            let ph = th.phase(t);
            let sk = hooks.suck(th, t);
            if let Some(c) = contribution(th, &ph, &setup.cfg, edge, pos, sk) {
                w += c.w;
                mask = mask.max(c.mask);
                edge2 += c.edge2;
            }
        }
        [w, mask, edge2.sqrt()]
    }
}
