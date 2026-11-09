//! Набор термиков вокруг фокуса и опрос (`ThermalField.sample`): сетка быстрого поиска (бакеты
//! `bucket_m`, в каждый вписана капсула оси термика с запасом на снос), результат
//! `(w, маска, σ края)`; ядра в радиусе физики вокруг фокуса — «активные».
use super::CloudHooks;
use super::bubble::{self, Blend, BubbleCache, Cell};
use super::cells::Setup;
use super::life::AtmoThermal;
use super::profile::{Edge, contribution};
use rayon::prelude::*;
use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};
use std::sync::Arc;

/// Быстрый хеш ключей ячеек поиска (два `i64`): SipHash по умолчанию — заметная доля цены опроса. Только поиск по
/// ключу, порядок обхода карты не используется — поле не зависит от хеша.
#[derive(Default)]
pub struct CellHasher(u64);
impl Hasher for CellHasher {
    #[inline]
    fn finish(&self) -> u64 {
        self.0
    }
    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0.rotate_left(5) ^ u64::from(b)).wrapping_mul(0x517c_c1b7_2722_0a95);
        }
    }
    #[inline]
    fn write_i64(&mut self, x: i64) {
        self.0 = (self.0.rotate_left(5) ^ x as u64).wrapping_mul(0x517c_c1b7_2722_0a95);
    }
}
type Cells = HashMap<(i64, i64), Vec<u32>, BuildHasherDefault<CellHasher>>;

/// Как термик `active` даёт подъём (TB4 v3: шаблон пузыря всегда).
#[derive(Clone, Debug)]
enum Mode {
    /// Профиль Гедеона: статичный, дальше `bubble_radius_m` от фокусов, столб ниже 100 м, пузыря нет (не родился,
    /// кончился, радиус 0) или таблица ещё не собрана (первая сборка идёт в фоне).
    Profile,
    /// Таблицы ключевых кадров пузыря и его положение.
    Table(Blend),
}

/// Капсула оси термика в плане: отрезок `p0 + u·d`, `u ∈ [0, 1]`, и радиус запаса.
#[derive(Clone, Copy, Debug)]
struct Capsule {
    p0: [f64; 2],
    d: [f64; 2],
    inv_l2: f64,
    r2: f64,
}

impl Capsule {
    fn new(p0: [f64; 2], p1: [f64; 2], r: f64) -> Capsule {
        let d = [p1[0] - p0[0], p1[1] - p0[1]];
        let l2 = d[0] * d[0] + d[1] * d[1];
        Capsule {
            p0,
            d,
            inv_l2: if l2 > 1.0e-12 { 1.0 / l2 } else { 0.0 },
            r2: r * r,
        }
    }

    /// Точка `(x, z)` в капсуле.
    #[inline]
    fn contains(&self, x: f64, z: f64) -> bool {
        let (ax, az) = (x - self.p0[0], z - self.p0[1]);
        let u = ((ax * self.d[0] + az * self.d[1]) * self.inv_l2).clamp(0.0, 1.0);
        let (ex, ez) = (ax - u * self.d[0], az - u * self.d[1]);
        ex * ex + ez * ez <= self.r2
    }
}

/// Пачка опроса: записей, читаемых за первый проход.
const CHUNK: usize = 8;

/// Итог первого прохода по термику с таблицей в радиусе таблиц: огибающая, смещение от оси и ячейки таблиц пары.
#[derive(Clone, Copy)]
struct Item<'a> {
    env: f64,
    dx: f64,
    dz: f64,
    rho: f64,
    cells: [Option<(f64, Cell<'a>)>; 2],
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
    /// Капсула влияния каждого активного термика (ось на момент сборки с запасом бакета): вне неё вклада нет — опрос не
    /// трогает термик.
    segs: Vec<Capsule>,
    /// Режим опроса параллельно `active`; пусто — все профилем (набор без таблиц, `stub`).
    bubbles: Vec<Mode>,
    buckets: Cells,
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
            segs: Vec::new(),
            bubbles: Vec::new(),
            buckets: Cells::default(),
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
            true,
        )
    }

    /// [`State::build`] с кешем таблиц пузырей (переносится между обновлениями набора). `tables = false` — таблиц не
    /// строить (синхронный `start_at`, кадр игры не ждёт): все термики опрашиваются профилем, пока фоновое обновление не
    /// соберёт таблицы.
    pub fn build_cached(
        setup: &Setup,
        all: Vec<Arc<AtmoThermal>>,
        t: f64,
        focuses: &[[f64; 2]],
        margin: f64,
        slot: i64,
        cache: &BubbleCache,
        tables: bool,
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
            segs: Vec::new(),
            bubbles: Vec::new(),
            buckets: Cells::default(),
            inv_bucket: 1.0 / bucket,
        };
        let cut = cfg.profile_cutoff_radii;
        let tables = tables.then(|| Self::bubble_modes(&st.all, t, focuses, margin, cfg, cache));
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
                st.segs.push(Capsule::new(p0, p1, pad + 1.0));
                if let Some(m) = mode {
                    st.bubbles.push(m);
                }
                st.insert_capsule(p0, p1, pad, off, bucket);
            }
        }
        st
    }

    /// Режимы термиков (кроме `Profile`, которого в карте нет). Динамический термик, чей круг влияния
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
                bubble::bubble_inputs(th).is_some()
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
                continue; // пузыря нет — профиль
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
    /// Опрос игры (TB4 v3): `w` пузырей (термики с таблицей) вместо `w` профиля, плюс горизонталь `uh` (x, z игры);
    /// `маска` и `σ` — из профиля. Статичные термики, дальше `bubble_radius_m`, столбы ниже 100 м и термики без таблицы
    /// (ещё не собрана, пузыря нет) дают `w` профиля, `uh = 0`. Термик с таблицей: ниже `top` — только таблица, от `top`
    /// до `top + cloud_depth` — `w` профиля (облачный подсос, продолжение столба в облако); шов на `top` — граница модели.
    /// [`State::sample`] — только профиль (прежний путь, бенч).
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
        // Два прохода по пачкам: первый считает профиль и читает узлы таблиц (независимые загрузки перекрывают промахи
        // кеша таблиц разных термиков), второй складывает в том же порядке, что и список.
        let (px, pz) = (f64::from(pos[0]), f64::from(pos[2]));
        let mut items = [None::<Item>; CHUNK];
        let mut n = 0usize;
        let flush = |items: &mut [Option<Item<'_>>], w: &mut f64, uh: &mut [f64; 2]| {
            // сначала читаем узлы всех ячеек подряд — промахи кеша перекрываются
            for it in items.iter_mut().flatten() {
                for (_, c) in it.cells.iter_mut().flatten() {
                    c.load();
                }
            }
            for it in items.iter().flatten() {
                // огибающая термика игры: плавный распад, к концу жизни вклад 0 (пузырь живёт дольше термика)
                let (wb, h) = Blend::mix(&it.cells, it.dx, it.dz, it.rho);
                *w += wb * it.env;
                uh[0] += h[0] * it.env;
                uh[1] += h[1] * it.env;
            }
        };
        for &o in list {
            if !self.segs[o as usize].contains(px, pz) {
                continue;
            }
            let th = &self.active[o as usize];
            let ph = th.phase(t);
            let sk = hooks.suck(th, t);
            let c = contribution(th, &ph, &setup.cfg, edge, pos, sk);
            if let Some(c) = &c {
                mask = mask.max(c.mask);
                edge2 += c.edge2;
            }
            match self.bubbles.get(o as usize) {
                Some(Mode::Table(mv)) if f64::from(pos[1]) < th.top => {
                    let high = f64::from(pos[1]) - f64::from(th.src[1]);
                    // TB4 v4: центр пузыря — ось термика игры на высоте головы (снос + наклон `lean`, как у
                    // `cores`), сдвиг пузыря целиком; шлейф ниже головы остаётся вертикальным (граница модели)
                    let zc = mv.frame(t).zc;
                    let ax = th.axis_at(f64::from(th.src[1]) + zc, ph.drift);
                    let dx = px - ax[0];
                    let dz = pz - ax[1];
                    let rho = (dx * dx + dz * dz).sqrt();
                    // дальше узлов таблиц вклада нет
                    if rho < mv.reach() {
                        items[n] = Some(Item {
                            env: ph.env,
                            dx,
                            dz,
                            rho,
                            cells: mv.cells(high, rho, t),
                        });
                        n += 1;
                        if n == CHUNK {
                            flush(&mut items, &mut w, &mut uh);
                            n = 0;
                            items = [None; CHUNK];
                        }
                    }
                }
                // профиль: нет таблицы, или выше `top` (облачный подсос — продолжение столба в облако)
                _ => w += c.map_or(0.0, |c| c.w),
            }
        }
        flush(&mut items[..n], &mut w, &mut uh);
        ([w, mask, edge2.sqrt()], uh)
    }
}
