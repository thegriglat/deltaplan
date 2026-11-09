//! Набор термиков вокруг фокуса и опрос (`ThermalField.sample`): сетка быстрого поиска (бакеты
//! `bucket_m`, в каждый вписана капсула оси термика с запасом на снос), результат
//! `(w, маска, σ края)`; ядра в радиусе физики вокруг фокуса — «активные».
use super::CloudHooks;
use super::bubble::{self, Blend, BubbleCache};
use super::cells::Setup;
use super::life::AtmoThermal;
use super::profile::{Edge, contribution};
use rayon::prelude::*;
use std::collections::HashMap;
use std::sync::Arc;

/// Как термик `active` даёт подъём при флаге `bubble_template` (TB4 v2).
#[derive(Clone, Debug)]
enum Mode {
    /// Профиль Гедеона, как без флага: статичный или дальше `bubble_radius_m` от фокусов.
    Profile,
    /// Динамический внутри `bubble_radius_m`, а пузыря нет (не родился, кончился, радиус 0): `w = 0`, `uh = 0`.
    NoTable,
    /// Таблицы ключевых кадров пузыря и его положение.
    Table(Blend),
}

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
    /// Шаблон пузыря (флаг `bubble_template`) параллельно `active`; без флага пусто.
    bubbles: Vec<Mode>,
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
        Self::build_cached(
            setup,
            all,
            t,
            focuses,
            margin,
            slot,
            &BubbleCache::default(),
        )
    }

    /// [`State::build`] с кешем таблиц пузырей (переносится между обновлениями набора).
    pub fn build_cached(
        setup: &Setup,
        all: Vec<Arc<AtmoThermal>>,
        t: f64,
        focuses: &[[f64; 2]],
        margin: f64,
        slot: i64,
        cache: &BubbleCache,
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
            .then(|| Self::bubble_modes(&st.all, t, focuses, margin, cfg, cache));
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
            let mode = tables
                .as_ref()
                .map(|m| m.get(&th.id).cloned().unwrap_or(Mode::Profile));
            if let Some(Mode::Table(mv)) = &mode {
                // запас бакета не меньше радиуса таблицы
                pad = pad.max(mv.r_max() + dv[0].hypot(dv[1]) * margin);
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
                if let Some(m) = mode {
                    st.bubbles.push(m);
                }
                st.insert_capsule(p0, p1, pad, off, bucket);
            }
        }
        st
    }

    /// Режимы термиков при флаге (кроме `Profile`, которого в карте нет). Динамический термик, чей круг влияния
    /// (радиус таблицы + снос за `margin`) задевает круг `bubble_radius_m` вокруг фокуса, получает пузырь: таблица из
    /// кеша по `id`, пересборка — когда она устарела ([`bubble::BubbleTable::stale`]). Радиус таблицы ещё не известен
    /// — предотбор по `R_GUESS_FRAC·z_l`, потом та же проверка с настоящим радиусом. Параллельно, порядок и биты не зависят от
    /// потоков.
    fn bubble_modes(
        all: &[Arc<AtmoThermal>],
        t: f64,
        focuses: &[[f64; 2]],
        margin: f64,
        cfg: &super::ThermalCfg,
        cache: &BubbleCache,
    ) -> HashMap<i64, Mode> {
        // круг влияния термика (капсула оси + запас) задевает круг `bubble_radius_m` вокруг фокуса
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
                .any(|f| (f[0] - mid[0]).hypot(f[1] - mid[1]) - half - pad <= cfg.bubble_radius_m)
        };
        // предотбор до расчёта источника: радиус таблицы ≤ `R_GUESS_FRAC·z_l` (проверяет `table_accuracy` на стадиях жизни)
        let cands: Vec<&Arc<AtmoThermal>> = all
            .iter()
            .filter(|th| {
                let zl = th.top - f64::from(th.src[1]);
                !th.is_static
                    && t <= th.t_end()
                    && near(th, (bubble::R_GUESS_FRAC * zl).min(bubble::R_CAP_M))
            })
            .collect();
        let t_start = std::time::Instant::now();
        // источники пузырей (дорого) — только новым термикам
        let fresh: Vec<&Arc<AtmoThermal>> = {
            let c = cache.lock();
            cands
                .iter()
                .filter(|th| !c.contains_key(&th.id))
                .copied()
                .collect()
        };
        let made: Vec<(i64, bubble::CacheEntry)> = fresh
            .par_iter()
            .map(|th| (th.id, bubble::CacheEntry::new(th)))
            .collect();
        cache.stats.source_ns.fetch_add(
            t_start.elapsed().as_nanos() as u64 * u64::from(!fresh.is_empty()),
            std::sync::atomic::Ordering::Relaxed,
        );
        cache
            .stats
            .sources
            .fetch_add(made.len() as u64, std::sync::atomic::Ordering::Relaxed);
        let entries: Vec<bubble::CacheEntry> = {
            let mut c = cache.lock();
            for (id, e) in made {
                c.insert(id, e);
            }
            // забыть ушедших
            let alive: std::collections::HashSet<i64> = all.iter().map(|th| th.id).collect();
            c.retain(|id, _| alive.contains(id));
            cands.iter().map(|th| c[&th.id].clone()).collect()
        };
        // ключевые кадры: нужны два соседних (j и j + 1) интервала, содержащего `t`; чего нет в кеше — построить
        let ivs: Vec<Option<usize>> = entries.iter().map(|e| e.interval(t)).collect();
        let todo: Vec<(usize, usize)> = (0..cands.len())
            .flat_map(|i| ivs[i].into_iter().flat_map(move |j| [(i, j), (i, j + 1)]))
            .filter(|&(i, j)| j < entries[i].kf.len() && entries[i].frame(j).is_none())
            .collect();
        let rebuilt: Vec<(usize, usize, Option<Arc<bubble::BubbleTable>>)> = todo
            .par_iter()
            .map(|&(i, j)| {
                let t0 = std::time::Instant::now();
                let (src, zi) = entries[i].src.as_ref().expect("источник есть");
                let traj = entries[i].traj.as_ref().expect("траектория есть");
                let tb =
                    bubble::build_keyframe(src, *zi, traj, cands[i].strength, entries[i].kf[j]);
                let ns = t0.elapsed().as_nanos() as u64;
                cache
                    .stats
                    .build_ns
                    .fetch_add(ns, std::sync::atomic::Ordering::Relaxed);
                (i, j, tb)
            })
            .collect();
        cache
            .stats
            .rebuilds
            .fetch_add(rebuilt.len() as u64, std::sync::atomic::Ordering::Relaxed);
        let mut frames: Vec<[Option<Arc<bubble::BubbleTable>>; 2]> = (0..cands.len())
            .map(|i| match ivs[i] {
                Some(j) => [j, j + 1].map(|k| entries[i].frame(k).cloned().flatten()),
                None => [None, None],
            })
            .collect();
        {
            let mut c = cache.lock();
            for (i, j, tb) in rebuilt {
                let j0 = ivs[i].expect("интервал есть");
                frames[i][j - j0] = tb.clone();
                if let Some(e) = c.get_mut(&cands[i].id) {
                    e.frames.push((j, tb));
                }
            }
            // держим три соседних кадра: прошлый, текущий интервал и следующий
            for (i, th) in cands.iter().enumerate() {
                if let (Some(j0), Some(e)) = (ivs[i], c.get_mut(&th.id)) {
                    e.frames.retain(|f| f.0 + 1 >= j0 && f.0 <= j0 + 2);
                }
            }
        }
        let mut out = HashMap::new();
        for (i, th) in cands.iter().enumerate() {
            let [fa, fb] = &frames[i];
            let st = entries[i].state_at(t);
            let (Some(st), Some(j0), true) = (st, ivs[i], fa.is_some() || fb.is_some()) else {
                // пузыря нет: внутри круга — вклада нет, снаружи — профиль
                if near(th, 0.0) {
                    out.insert(th.id, Mode::NoTable);
                }
                continue;
            };
            let bl_r = fa
                .as_ref()
                .map_or(0.0, |x| x.r_max)
                .max(fb.as_ref().map_or(0.0, |x| x.r_max));
            if !near(th, bl_r) {
                continue;
            }
            let f0 = bubble::Frame::of(&st);
            let dt = margin.max(0.1);
            let f1 = entries[i]
                .state_at(t + dt)
                .map_or(f0, |s| bubble::Frame::of(&s));
            let kf = &entries[i].kf;
            out.insert(
                th.id,
                Mode::Table(Blend {
                    a: fa.clone(),
                    b: fb.clone(),
                    t_a: kf[j0],
                    t_b: kf
                        .get(j0 + 1)
                        .copied()
                        .unwrap_or(kf[j0] + bubble::KEYFRAME_SLOW_S),
                    t0: t,
                    f0,
                    rate: bubble::Frame {
                        zb: (f1.zb - f0.zb) / dt,
                        zc: (f1.zc - f0.zc) / dt,
                    },
                }),
            );
        }
        out
    }

    /// Сколько активных термиков получили таблицы пузыря (тесты, отладка).
    pub fn bubble_count(&self) -> usize {
        self.bubbles
            .iter()
            .filter(|m| matches!(m, Mode::Table(_)))
            .count()
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
    /// плюс горизонталь `uh` (x, z игры); `маска` и `σ` — из профиля, как без флага. Статичные термики и динамические
    /// дальше `bubble_radius_m` дают `w` профиля; динамический внутри радиуса без пузыря — `w = 0`, `uh = 0`.
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
            match self.bubbles.get(o as usize) {
                Some(Mode::Table(mv)) => {
                    let high = f64::from(pos[1]) - f64::from(th.src[1]);
                    let dx = f64::from(pos[0]) - (f64::from(th.src[0]) + f64::from(ph.drift[0]));
                    let dz = f64::from(pos[2]) - (f64::from(th.src[2]) + f64::from(ph.drift[1]));
                    // огибающая термика игры: плавный распад, к концу жизни вклад 0 (пузырь живёт дольше термика)
                    let (wb, h) = mv.eval(high, dx, dz, t);
                    w += wb * ph.env;
                    uh[0] += h[0] * ph.env;
                    uh[1] += h[1] * ph.env;
                }
                Some(Mode::NoTable) => {}
                Some(Mode::Profile) | None => {
                    if let Some(c) = &c {
                        w += c.w;
                    }
                }
            }
        }
        ([w, mask, edge2.sqrt()], uh)
    }
}
