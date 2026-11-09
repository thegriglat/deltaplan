//! Набор термиков вокруг фокуса и опрос (`ThermalField.sample`): сетка быстрого поиска (бакеты
//! `bucket_m`, в каждый вписана капсула оси термика с запасом на снос), результат
//! `(w, маска, σ края)`; ядра в радиусе физики вокруг фокуса — «активные».
use super::CloudHooks;
use super::bubble::{self, BubbleTable};
use super::cells::Setup;
use super::life::AtmoThermal;
use super::profile::{Edge, contribution};
use rayon::prelude::*;
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
    /// Таблицы шаблона пузыря (флаг `bubble_template`) параллельно `active`; без флага пусто.
    bubbles: Vec<Option<Arc<BubbleTable>>>,
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
            bubbles: Vec::new(),
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
            bubbles: Vec::new(),
            buckets: HashMap::new(),
            inv_bucket: 1.0 / bucket,
        };
        let cut = cfg.profile_cutoff_radii;
        let tables = cfg
            .bubble_template
            .then(|| Self::bubble_tables(&st.all, t, focuses, margin, cfg));
        for th in st.all.clone() {
            if !(th.is_static || t <= th.t_end()) {
                continue;
            }
            let ph = th.phase(t);
            let p0 = th.axis_at(f64::from(th.src[1]), ph.drift);
            // поток продолжается внутрь облака (подсос): столб до верха облака
            let mut p1 = th.axis_at(th.top + th.cloud_depth, ph.drift);
            let dv = [f64::from(th.drift_vel[0]), f64::from(th.drift_vel[1])];
            let mut pad = th.radius * cut + dv[0].hypot(dv[1]) * margin;
            let table = tables.as_ref().and_then(|m| m.get(&th.id)).cloned();
            if let Some(tb) = &table {
                // запас бакета не меньше радиуса таблицы
                pad = pad.max(tb.r_max + dv[0].hypot(dv[1]) * margin);
            }
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
                if tables.is_some() {
                    st.bubbles.push(table);
                }
                st.insert_capsule(p0, p1, pad, off, bucket);
            }
        }
        st
    }

    /// Таблицы пузырей для термиков, которые окажутся активными. Отбор в два шага: сначала с запасом
    /// `R_CAP_M` (радиус таблицы ещё не известен) считаются пузырь и радиус влияния, затем та же проверка
    /// «рядом с фокусом», что и в [`State::build`], но с настоящим радиусом; таблицы строятся только для
    /// прошедших. Параллельно, порядок и биты не зависят от потоков.
    fn bubble_tables(
        all: &[Arc<AtmoThermal>],
        t: f64,
        focuses: &[[f64; 2]],
        margin: f64,
        cfg: &super::ThermalCfg,
    ) -> HashMap<i64, Arc<BubbleTable>> {
        // та же геометрия, что в основном цикле `build`; `table_r` — радиус таблицы в запасе бакета
        let near = |th: &AtmoThermal, table_r: f64| -> bool {
            let ph = th.phase(t);
            let p0 = th.axis_at(f64::from(th.src[1]), ph.drift);
            let mut p1 = th.axis_at(th.top + th.cloud_depth, ph.drift);
            let dv = [f64::from(th.drift_vel[0]), f64::from(th.drift_vel[1])];
            let dvm = dv[0].hypot(dv[1]) * margin;
            let pad = (th.radius * cfg.profile_cutoff_radii + dvm).max(table_r + dvm);
            if !th.is_static && t + margin > th.drift_start() {
                p1[0] += dv[0] * margin;
                p1[1] += dv[1] * margin;
            }
            let mid = [(p0[0] + p1[0]) * 0.5, (p0[1] + p1[1]) * 0.5];
            let half = (p0[0] - p1[0]).hypot(p0[1] - p1[1]) * 0.5;
            focuses
                .iter()
                .any(|f| (f[0] - mid[0]).hypot(f[1] - mid[1]) - half - pad <= cfg.physics_radius_m)
        };
        let cands: Vec<&Arc<AtmoThermal>> = all
            .iter()
            .filter(|th| !th.is_static && t <= th.t_end() && near(th, bubble::R_CAP_M))
            .collect();
        let prep: Vec<Option<(bubble::Bubble, f64, f64)>> =
            cands.par_iter().map(|th| bubble::prepare(th, t)).collect();
        let todo: Vec<(i64, &(bubble::Bubble, f64, f64))> = cands
            .iter()
            .zip(&prep)
            .filter_map(|(th, p)| p.as_ref().map(|p| (th, p)))
            .filter(|(th, p)| near(th, p.2))
            .map(|(th, p)| (th.id, p))
            .collect();
        let built: Vec<Arc<BubbleTable>> = todo
            .par_iter()
            .map(|(_, (b, zi, r))| Arc::new(BubbleTable::build(b, *zi, *r, t)))
            .collect();
        todo.iter().map(|x| x.0).zip(built).collect()
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

impl State {
    /// [`State::sample`] при флаге `bubble_template`: `w` пузырей (термики с таблицей) вместо `w` профиля,
    /// плюс горизонталь `uh` (x, z игры); `маска` и `σ` — из профиля, как без флага. Термики без таблицы
    /// (статичные, пузыря нет) дают `w` профиля.
    pub fn sample_bubble(
        &self,
        setup: &Setup,
        hooks: &dyn CloudHooks,
        pos: [f32; 3],
        t: f64,
    ) -> ([f64; 3], [f64; 2]) {
        let key = (
            (f64::from(pos[0]) * self.inv_bucket).floor() as i64,
            (f64::from(pos[2]) * self.inv_bucket).floor() as i64,
        );
        let Some(list) = self.buckets.get(&key) else {
            return ([0.0; 3], [0.0; 2]);
        };
        let edge = Edge {
            k: setup.edge_k,
            w: setup.edge_w,
        };
        let (mut w, mut mask, mut edge2) = (0.0f64, 0.0f64, 0.0f64);
        let mut uh = [0.0f64; 2];
        for &o in list {
            let th = &self.active[o as usize];
            let ph = th.phase(t);
            let sk = hooks.suck(th, t);
            let c = contribution(th, &ph, &setup.cfg, edge, pos, sk);
            if let Some(c) = &c {
                mask = mask.max(c.mask);
                edge2 += c.edge2;
            }
            match self.bubbles.get(o as usize).and_then(Option::as_ref) {
                Some(tb) => {
                    let high = f64::from(pos[1]) - f64::from(th.src[1]);
                    let dx = f64::from(pos[0]) - (f64::from(th.src[0]) + f64::from(ph.drift[0]));
                    let dz = f64::from(pos[2]) - (f64::from(th.src[2]) + f64::from(ph.drift[1]));
                    let (wb, h) = tb.eval(high, dx, dz, t);
                    w += wb;
                    uh[0] += h[0];
                    uh[1] += h[1];
                }
                None => {
                    if let Some(c) = &c {
                        w += c.w;
                    }
                }
            }
        }
        ([w, mask, edge2.sqrt()], uh)
    }
}
