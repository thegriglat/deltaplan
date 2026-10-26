//! `Formula` — формульная модель воздуха (W4): среднее поле Пикара, которое ведёт сам крейт.
//!
//! Что делает: `load_place` → фон (`field::runtime::run_job`: вход области, грубый старт, пара
//! mech/heat, проходы `k`) → набор уровней `FieldSet` → опросы; на сроке `recompute_game_min` и
//! при смене условий — пересчёт с тёплого старта и подмена за `blend_s`.
//!
//! ## Потоки
//! - Команды (`&mut self`) — один поток; опросы (`&self`) — любые потоки одновременно, читают
//!   последний готовый снимок `Arc<Published>` (`RwLock` держится на время подмены указателя,
//!   не на время расчёта).
//! - Фон — задача в `rayon`-пуле на процесс (по размеру `air.threads`; `0` — все ядра минус
//!   одно); внутри — `picard_rs::api::solve` с тем же числом потоков. Отмена — `AtomicBool`
//!   (W11): `unload_place`, `load_place`, `start_at`, `Drop` ждут конца задачи (≤ 1 итерация
//!   решения или конец стадии подготовки; не дольше 5 с — дальше задача отпускается и её поле
//!   не подаётся).
//! - Загрузка и `start_at` подаются сами фоном (без подмены), пересчёт в полёте — главным
//!   потоком в `advance_to`: при `air.deterministic = true` `advance_to` на игровом моменте
//!   подачи (начало срока `recompute_game_min` или момент смены условий) ждёт фон и подаёт поле
//!   с началом подмены в этот момент; иначе не ждёт и подаёт готовое при следующем `advance_to`.
//!
//! ## Границы модели
//! - Слагаемое одно — `field` (FULL = MEAN, σ = 0); вне области поля — нули (аналитика — RW-9).
//! - Статические термики, солнце, погода, облака, волны — не реализованы (RW-8…12): команды
//!   принимаются и проверяются, опросы отдают нули.
//! - `Failed`: опросы по запасному пути — нули (аналитики пока нет).
//! - Загрузка без условий — `Ready` без поля; поле считается с первым `advance_to` после
//!   `set_conditions` (режим «нет поля»: `Loading`).
//! - Проходы `k` — без окон 100/50 м (см. `field::runtime`).
use crate::field::field_set::FieldSet;
use crate::field::runtime::{
    CondRec, JobErr, JobIn, JobOut, JobReport, Pair, RtCfg, dir_key, ground_height,
    needs_recompute, run_job, slot, slot_hour,
};
use crate::field::weather_core::{WeatherInputs, hour_at};
use crate::field::wind_field::Limits;
use crate::{
    AirModel, Cloud, Conditions, Configs, Core, Crest, Decomposition, Error, Focus, Place, Raster,
    SampleMode, State, Status,
};
use rayon::prelude::*;
use std::collections::HashMap;
use std::panic::AssertUnwindSafe;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, RwLock};
use std::time::{Duration, Instant};

/// Дольше этого `unload_place`/`Drop`/`load_place` не ждут конца задачи.
const JOIN_LIMIT: Duration = Duration::from_secs(5);

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

// ---------------------------------------------------------------- общее состояние

/// Снимок для опросов: набор уровней и место (рельеф для сдвига по земле).
#[derive(Clone)]
struct Published {
    fs: FieldSet,
    place: Option<Arc<Place>>,
}

struct Shared {
    published: RwLock<Arc<Published>>,
    state: AtomicU8,
    progress: Arc<AtomicU32>,
    time_bits: AtomicU64,
    reason: Mutex<String>,
    /// Журнал последней поданной задачи.
    report: Mutex<Option<JobReport>>,
    /// Поколение места: задача прежнего места ничего не подаёт.
    epoch: AtomicU64,
}

impl Shared {
    fn new() -> Self {
        Shared {
            published: RwLock::new(Arc::new(Published {
                fs: FieldSet::default(),
                place: None,
            })),
            state: AtomicU8::new(State::Empty.as_int() as u8),
            progress: Arc::new(AtomicU32::new(0f32.to_bits())),
            time_bits: AtomicU64::new(0f64.to_bits()),
            reason: Mutex::new(String::new()),
            report: Mutex::new(None),
            epoch: AtomicU64::new(0),
        }
    }

    fn snapshot(&self) -> Arc<Published> {
        self.published
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Копия при записи: читатели держат прежний `Arc`.
    fn modify(&self, f: impl FnOnce(&mut Published)) {
        let mut g = self
            .published
            .write()
            .unwrap_or_else(PoisonError::into_inner);
        let mut p = Published::clone(&g);
        f(&mut p);
        *g = Arc::new(p);
    }

    /// То же, если поколение не сменилось (проверка — под замком записи).
    fn modify_epoch(&self, epoch: u64, f: impl FnOnce(&mut Published)) -> bool {
        let mut g = self
            .published
            .write()
            .unwrap_or_else(PoisonError::into_inner);
        if self.epoch.load(Ordering::SeqCst) != epoch {
            return false;
        }
        let mut p = Published::clone(&g);
        f(&mut p);
        *g = Arc::new(p);
        true
    }

    fn set_state(&self, s: State, progress: f32, reason: &str) {
        self.progress.store(progress.to_bits(), Ordering::Relaxed);
        *lock(&self.reason) = reason.to_string();
        self.state.store(s.as_int() as u8, Ordering::SeqCst);
    }

    fn state(&self) -> State {
        match self.state.load(Ordering::SeqCst) {
            1 => State::Loading,
            2 => State::Ready,
            3 => State::Failed,
            _ => State::Empty,
        }
    }

    /// Продвинуть подмену набора на `dt` с (копия только пока она идёт).
    fn advance_fs(&self, dt: f64) {
        if dt <= 0.0 || self.snapshot().fs.blend_fraction() >= 1.0 {
            return;
        }
        self.modify(|p| p.fs.advance(dt));
    }

    fn set_time(&self, t: f64) {
        self.time_bits.store(t.to_bits(), Ordering::SeqCst);
    }
}

// ---------------------------------------------------------------- фон

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    /// Первое поле места: час как есть, проходы `k`, подаёт сама задача.
    Load,
    /// Прыжок `start_at`: пересчёт с тёплого старта, подаёт сама задача.
    Start,
    /// Пересчёт в полёте: подаёт главный поток с подменой.
    Flight,
}

/// Итог задачи; пусто — идёт.
struct Slot {
    res: Mutex<Option<Result<JobOut, JobErr>>>,
    cv: Condvar,
}

impl Slot {
    fn new() -> Arc<Self> {
        Arc::new(Slot {
            res: Mutex::new(None),
            cv: Condvar::new(),
        })
    }

    fn put(&self, r: Result<JobOut, JobErr>) {
        *lock(&self.res) = Some(r);
        self.cv.notify_all();
    }

    fn is_done(&self) -> bool {
        lock(&self.res).is_some()
    }

    fn take(&self) -> Option<Result<JobOut, JobErr>> {
        lock(&self.res).take()
    }

    /// Ждёт конца задачи; `false` — вышло время.
    fn wait(&self, limit: Option<Duration>) -> bool {
        let end = limit.map(|d| Instant::now() + d);
        let mut g = lock(&self.res);
        while g.is_none() {
            match end {
                None => g = self.cv.wait(g).unwrap_or_else(PoisonError::into_inner),
                Some(e) => {
                    let left = e.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        return false;
                    }
                    g = self
                        .cv
                        .wait_timeout(g, left)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0;
                }
            }
        }
        true
    }
}

struct Job {
    kind: Kind,
    cancel: Arc<AtomicBool>,
    slot: Arc<Slot>,
    /// Игровой момент подачи (детерминированный режим).
    deliver_t: f64,
    rec: CondRec,
    blend_s: f64,
}

/// Пул фона на процесс по размеру.
fn pool_for(threads: usize) -> Option<Arc<rayon::ThreadPool>> {
    static POOLS: Mutex<Vec<(usize, Arc<rayon::ThreadPool>)>> = Mutex::new(Vec::new());
    let mut g = lock(&POOLS);
    if let Some((_, p)) = g.iter().find(|(n, _)| *n == threads) {
        return Some(p.clone());
    }
    let p = Arc::new(
        rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .thread_name(|i| format!("dp-air-{i}"))
            .build()
            .ok()?,
    );
    g.push((threads, p.clone()));
    Some(p)
}

fn spawn_bg(threads: usize, f: impl FnOnce() + Send + 'static) {
    match pool_for(threads) {
        Some(p) => p.spawn(f),
        None => {
            // пул не создался (лимит потоков): отдельный поток, rayon внутри — глобальный
            let _ = std::thread::Builder::new()
                .name("dp-air-job".into())
                .spawn(f);
        }
    }
}

fn apply_limits(p: &mut Published, cfg: &RtCfg) {
    p.fs.limits = cfg.limits;
    p.fs.edge_cells = cfg.edge_blend_cells;
}

/// Тело фоновой задачи.
fn job_main(sh: Arc<Shared>, kind: Kind, epoch: u64, job: JobIn, slot: Arc<Slot>) {
    let cfg = job.cfg.clone();
    let res = std::panic::catch_unwind(AssertUnwindSafe(|| run_job(job)))
        .unwrap_or_else(|_| Err(JobErr::Failed("internal error in the field task".into())));
    let res = match res {
        Ok(mut out) => {
            if kind != Kind::Flight {
                let levels = std::mem::take(&mut out.levels);
                sh.modify_epoch(epoch, |p| {
                    apply_limits(p, &cfg);
                    p.fs.set_field(levels, 0.0);
                    *lock(&sh.report) = Some(out.report.clone());
                    sh.set_state(State::Ready, 1.0, "");
                });
            }
            Ok(out)
        }
        Err(JobErr::Failed(m)) => {
            match kind {
                Kind::Load => {
                    sh.modify_epoch(epoch, |_| sh.set_state(State::Failed, 0.0, &m));
                }
                Kind::Start => {
                    sh.modify_epoch(epoch, |_| sh.set_state(State::Ready, 1.0, &m));
                }
                Kind::Flight => {}
            }
            Err(JobErr::Failed(m))
        }
        Err(JobErr::Cancelled) => Err(JobErr::Cancelled),
    };
    slot.put(res);
}

// ---------------------------------------------------------------- Formula

/// Формульная модель воздуха. См. описание модуля.
pub struct Formula {
    sh: Arc<Shared>,
    force_det: Option<bool>,
    configs: Arc<Configs>,
    cfg: Option<Result<Arc<RtCfg>, String>>,
    seed: u64,
    cond: Option<Conditions>,
    inputs: Option<Result<WeatherInputs, String>>,
    sun: Option<[f32; 3]>,
    thermals: Vec<[f32; 4]>,
    thermals_mode: u8,
    focuses: Vec<Focus>,
    place: Option<Arc<Place>>,
    time_s: f64,
    /// Условия поля в атмосфере (`None` — поля нет).
    cur: Option<CondRec>,
    warm: Option<Arc<Pair>>,
    inflow_k: f64,
    k_mem: HashMap<i32, f64>,
    job: Option<Job>,
    /// Игровое время последней смены условий.
    cond_t: f64,
    force_recompute: bool,
    /// Первое поле не посчиталось: новых попыток нет до `load_place`.
    failed: bool,
}

impl Default for Formula {
    fn default() -> Self {
        Self::new()
    }
}

impl Formula {
    pub fn new() -> Self {
        Formula {
            sh: Arc::new(Shared::new()),
            force_det: None,
            configs: Arc::new(Configs::default()),
            cfg: None,
            seed: 0,
            cond: None,
            inputs: None,
            sun: None,
            thermals: Vec::new(),
            thermals_mode: 0,
            focuses: Vec::new(),
            place: None,
            time_s: 0.0,
            cur: None,
            warm: None,
            inflow_k: 1.0,
            k_mem: HashMap::new(),
            job: None,
            cond_t: 0.0,
            force_recompute: false,
            failed: false,
        }
    }

    /// Задать `air.deterministic` в обход конфига (тесты, стенд, фикстуры — `true`).
    pub fn with_deterministic(mut self, on: bool) -> Self {
        self.force_det = Some(on);
        self
    }

    /// Журнал последней принятой задачи (итерации, проходы `k`, заметки).
    pub fn report(&self) -> Option<JobReport> {
        lock(&self.sh.report).clone()
    }

    /// Множитель притока поля в атмосфере.
    pub fn inflow_k(&self) -> f64 {
        self.inflow_k
    }

    /// Условия поля в атмосфере.
    pub fn current(&self) -> Option<&CondRec> {
        self.cur.as_ref()
    }

    /// Ждёт конца идущей задачи (без подачи); `false` — вышло время. Для тестов.
    pub fn wait_job(&self, limit: Duration) -> bool {
        self.job.as_ref().is_none_or(|j| j.slot.wait(Some(limit)))
    }

    fn det(&self) -> bool {
        matches!(&self.cfg, Some(Ok(c)) if c.deterministic)
    }

    fn need_place(&self) -> Result<(), Error> {
        if self.place.is_some() {
            Ok(())
        } else {
            Err(Error::no_place("place is not loaded"))
        }
    }

    fn check_time(t: f64) -> Result<(), Error> {
        if t.is_finite() && t >= 0.0 {
            Ok(())
        } else {
            Err(Error::bad_input(format!(
                "time {t} must be finite and >= 0"
            )))
        }
    }

    fn cfg_ok(&self) -> Result<Arc<RtCfg>, String> {
        match &self.cfg {
            Some(Ok(c)) => Ok(c.clone()),
            Some(Err(m)) => Err(m.clone()),
            None => Err("configure() was not called".into()),
        }
    }

    fn recompute_inputs(&mut self) {
        self.inputs = self
            .cond
            .as_ref()
            .map(|c| WeatherInputs::from_conditions(c, &self.configs).map_err(|e| e.msg));
    }

    fn set_time(&mut self, t: f64) {
        self.time_s = t;
        self.sh.set_time(t);
    }

    /// Останавливает идущую задачу и ждёт её (не дольше `JOIN_LIMIT`; дальше — отпускает и
    /// сменой поколения лишает права подавать).
    fn cancel_job(&mut self) {
        if let Some(job) = self.job.take() {
            job.cancel.store(true, Ordering::SeqCst);
            if !job.slot.wait(Some(JOIN_LIMIT)) {
                self.sh.epoch.fetch_add(1, Ordering::SeqCst);
            }
        }
    }

    /// Ошибка задачи: первое поле — `Failed`, пересчёт — прежнее поле, условия считаются
    /// учтёнными (следующая попытка — на следующем сроке или смене условий).
    fn job_failed(&mut self, kind: Kind, rec: CondRec, msg: String) {
        if kind == Kind::Load {
            self.failed = true;
            self.sh.set_state(State::Failed, 0.0, &msg);
        } else {
            if let Some(c) = self.cur.as_mut() {
                c.hour = rec.hour;
                c.u10 = rec.u10;
                c.wdir = rec.wdir;
                c.t_max = rec.t_max;
                c.sky = rec.sky;
                c.inflow = rec.inflow;
            }
            *lock(&self.sh.reason) = msg;
        }
    }

    /// Принимает готовую задачу: учёт состояния; пересчёт в полёте подаёт в набор.
    fn adopt(&mut self, job: Job, res: Result<JobOut, JobErr>, t: f64, cursor: &mut f64) {
        let out = match res {
            Err(JobErr::Cancelled) => return,
            Err(JobErr::Failed(m)) => return self.job_failed(job.kind, job.rec, m),
            Ok(o) => o,
        };
        if job.kind == Kind::Flight {
            let det = self.det();
            let tdel = if det {
                job.deliver_t.clamp(*cursor, t.max(*cursor))
            } else {
                *cursor
            };
            let (cfg, blend) = (self.cfg_ok().ok(), job.blend_s);
            let levels = out.levels;
            self.sh.modify(|p| {
                if let Some(c) = &cfg {
                    apply_limits(p, c);
                }
                p.fs.advance(tdel - *cursor);
                p.fs.set_field(levels, blend);
            });
            *cursor = tdel;
        } else if job.kind == Kind::Load && out.report.planned > 1 {
            self.k_mem.insert(dir_key(out.rec.wdir), out.k);
        }
        self.cur = Some(out.rec);
        self.warm = Some(out.pair);
        self.inflow_k = out.k;
        if job.kind == Kind::Flight {
            *lock(&self.sh.report) = Some(out.report);
        }
    }

    /// Запускает задачу `kind` для условий `rec`.
    fn launch(&mut self, kind: Kind, rec: CondRec, deliver_t: f64) {
        let (Some(cond), Some(place)) = (self.cond.clone(), self.place.clone()) else {
            return;
        };
        let cfg = match self.cfg_ok() {
            Ok(c) => c,
            Err(m) => return self.job_failed(kind, rec, m),
        };
        let epoch = self.sh.epoch.load(Ordering::SeqCst);
        let cancel = Arc::new(AtomicBool::new(false));
        let slot = Slot::new();
        let progress = if kind == Kind::Flight {
            Arc::new(AtomicU32::new(0f32.to_bits()))
        } else {
            self.sh.set_state(State::Loading, 0.0, "");
            self.sh.progress.clone()
        };
        let loading = kind == Kind::Load;
        let job_in = JobIn {
            cfg: cfg.clone(),
            configs: self.configs.clone(),
            place,
            cond: cond.clone(),
            rec: rec.clone(),
            loading,
            k_mem: self.k_mem.get(&dir_key(rec.wdir)).copied(),
            inflow_k: self.inflow_k,
            focus: self.focuses.first().map(|f| [f.pos[0], f.pos[2]]),
            warm: if loading { None } else { self.warm.clone() },
            cancel: cancel.clone(),
            progress,
        };
        let sh = self.sh.clone();
        let sl = slot.clone();
        spawn_bg(cfg.threads, move || job_main(sh, kind, epoch, job_in, sl));
        self.job = Some(Job {
            kind,
            cancel,
            slot,
            deliver_t,
            rec,
            blend_s: cond.blend_s.unwrap_or(cfg.blend_s),
        });
    }

    /// Нужен ли пересчёт на моменте `t`; запускает задачу. `cursor` — игровое время, до
    /// которого подмена уже продвинута.
    fn try_launch(&mut self, t: f64, cursor: f64) -> bool {
        if self.failed || self.place.is_none() {
            return false;
        }
        let plan = self.plan(t, cursor);
        match plan {
            Ok(Some((kind, rec, deliver_t))) => {
                self.launch(kind, rec, deliver_t);
                true
            }
            Ok(None) => false,
            Err(m) => {
                if self.cur.is_none() {
                    self.failed = true;
                    self.sh.set_state(State::Failed, 0.0, &m);
                }
                false
            }
        }
    }

    /// Что запускать на моменте `t` (без выделений, пока пересчёт не нужен).
    fn plan(&mut self, t: f64, cursor: f64) -> Result<Option<(Kind, CondRec, f64)>, String> {
        let (Some(cond), Some(inputs)) = (&self.cond, &self.inputs) else {
            return Ok(None);
        };
        let cfg = self.cfg_ok()?;
        let inputs = inputs.as_ref().map_err(Clone::clone)?;
        if self.cur.is_none() {
            let rec = CondRec::new(inputs, cond, hour_at(cond, cursor));
            return Ok(Some((Kind::Load, rec, cursor)));
        }
        let hour = hour_at(cond, t);
        let cur = self.cur.as_ref();
        let same = cur.is_some_and(|c| {
            c.u10 == inputs.u10
                && c.wdir == inputs.wdir
                && c.t_max == inputs.t_max
                && c.sky == inputs.sky
                && c.inflow == cond.inflow_mode
        });
        // дёшево: те же условия и тот же срок — пересчёта нет
        if same
            && !self.force_recompute
            && cur.is_some_and(|c| slot(hour, cfg.step_min) == slot(c.hour, cfg.step_min))
        {
            return Ok(None);
        }
        let want = CondRec::new(inputs, cond, hour);
        let reason = needs_recompute(cur, &want, cfg.step_min)
            .or_else(|| self.force_recompute.then_some("перестройка"));
        if reason.is_none() {
            return Ok(None);
        }
        let sh = slot_hour(hour, cfg.step_min);
        let mut ev = self.cond_t;
        if let Some(c) = cur
            && slot(hour, cfg.step_min) != slot(c.hour, cfg.step_min)
        {
            ev = ev.max((sh - cond.start_hour) * 3600.0 / cond.speed);
        }
        let deliver_t = ev.clamp(cursor, t.max(cursor));
        self.force_recompute = false;
        Ok(Some((
            Kind::Flight,
            CondRec { hour: sh, ..want },
            deliver_t,
        )))
    }

    /// Ход фона до момента `t`: подача готового, запуск пересчёта, продвижение подмены.
    fn pump(&mut self, t: f64) {
        let mut cursor = self.time_s;
        for _ in 0..8 {
            if self.job.is_none() && !self.try_launch(t, cursor) {
                break;
            }
            let Some(job) = self.job.as_ref() else { break };
            let done = job.slot.is_done();
            if !done && !(self.det() && t >= job.deliver_t) {
                break;
            }
            if !done {
                job.slot.wait(None);
            }
            let Some(job) = self.job.take() else { break };
            let Some(res) = job.slot.take() else { break };
            self.adopt(job, res, t, &mut cursor);
        }
        self.sh.advance_fs(t - cursor);
    }

    /// Принимает завершённую задачу без продвижения времени (перед командами).
    fn reap(&mut self) {
        if self.job.as_ref().is_some_and(|j| j.slot.is_done())
            && let Some(job) = self.job.take()
            && let Some(res) = job.slot.take()
        {
            let mut cursor = self.time_s;
            let t = self.time_s;
            self.adopt(job, res, t, &mut cursor);
        }
    }

    fn reset_published(&self, place: Option<Arc<Place>>) {
        let (limits, edge) = match &self.cfg {
            Some(Ok(c)) => (c.limits, c.edge_blend_cells),
            _ => (Limits::default(), 5.0),
        };
        let mut g = self
            .sh
            .published
            .write()
            .unwrap_or_else(PoisonError::into_inner);
        *g = Arc::new(Published {
            fs: FieldSet::new(limits, edge),
            place,
        });
    }
}

impl Drop for Formula {
    fn drop(&mut self) {
        self.cancel_job();
    }
}

fn sample_point(pb: &Published, p: [f32; 3]) -> [f32; 4] {
    if !p.iter().all(|v| v.is_finite()) {
        return [0.0; 4];
    }
    let Some(place) = &pb.place else {
        return [0.0; 4];
    };
    if !pb.fs.is_active() {
        return [0.0; 4];
    }
    let g = ground_height(place, p[0], p[2]);
    let v = pb.fs.sample(p, g);
    let f = |x: f64| {
        let y = x as f32;
        if y.is_finite() { y } else { 0.0 }
    };
    [f(v.v[0]), f(v.v[1]), f(v.v[2]), 0.0]
}

impl AirModel for Formula {
    fn configure(&mut self, cfg: &Configs, seed: u64) -> Result<(), Error> {
        cfg.parse()?;
        self.configs = Arc::new(cfg.clone());
        self.seed = seed;
        let det = self.force_det;
        self.cfg = Some(RtCfg::from_configs(cfg).map_err(|e| e.msg).map(|mut c| {
            if let Some(d) = det {
                c.deterministic = d;
            }
            Arc::new(c)
        }));
        self.recompute_inputs();
        Ok(())
    }

    fn load_place(&mut self, place: Place) -> Result<(), Error> {
        self.cancel_job();
        self.sh.epoch.fetch_add(1, Ordering::SeqCst);
        let place = Arc::new(place);
        self.place = Some(place.clone());
        self.time_s = 0.0;
        self.sh.set_time(0.0);
        self.cur = None;
        self.warm = None;
        self.inflow_k = 1.0;
        self.k_mem.clear();
        self.failed = false;
        *lock(&self.sh.report) = None;
        self.cond_t = 0.0;
        self.reset_published(Some(place));
        self.sh.set_state(State::Ready, 1.0, "");
        if let (Some(cond), Some(inputs)) = (self.cond.clone(), self.inputs.clone()) {
            match inputs {
                Ok(i) => {
                    let rec = CondRec::new(&i, &cond, hour_at(&cond, 0.0));
                    self.launch(Kind::Load, rec, 0.0);
                }
                Err(m) => {
                    self.failed = true;
                    self.sh.set_state(State::Failed, 0.0, &m);
                }
            }
        }
        Ok(())
    }

    fn unload_place(&mut self) {
        self.cancel_job();
        self.sh.epoch.fetch_add(1, Ordering::SeqCst);
        self.place = None;
        self.time_s = 0.0;
        self.sh.set_time(0.0);
        self.cur = None;
        self.warm = None;
        self.inflow_k = 1.0;
        self.k_mem.clear();
        self.failed = false;
        *lock(&self.sh.report) = None;
        self.thermals.clear();
        self.focuses.clear();
        self.reset_published(None);
        self.sh.set_state(State::Empty, 0.0, "");
    }

    fn set_conditions(&mut self, c: &Conditions) -> Result<(), Error> {
        self.reap();
        if self.cond.as_ref() != Some(c) {
            self.cond_t = self.time_s;
        }
        self.force_recompute = c.rebuild;
        self.cond = Some(c.clone());
        self.recompute_inputs();
        Ok(())
    }

    fn set_sun_direction(&mut self, to_sun: Option<[f32; 3]>) {
        self.sun = to_sun.filter(|d| d.iter().all(|v| v.is_finite()));
    }

    fn set_static_thermals(&mut self, list: &[[f32; 4]], mode: u8) -> Result<(), Error> {
        if list.iter().flatten().any(|v| !v.is_finite()) {
            return Err(Error::bad_input("thermals: NaN/inf"));
        }
        self.thermals = list.to_vec();
        self.thermals_mode = mode;
        Ok(())
    }

    fn set_focuses(&mut self, f: &[Focus]) -> Result<(), Error> {
        if f.iter().any(|x| {
            !(x.pos.iter().all(|v| v.is_finite()) && x.weight.is_finite() && x.weight >= 0.0)
        }) {
            return Err(Error::bad_input("focuses: NaN/inf or negative weight"));
        }
        self.focuses = f.to_vec();
        Ok(())
    }

    fn advance_to(&mut self, t: f64) -> Result<(), Error> {
        Self::check_time(t)?;
        self.need_place()?;
        if t < self.time_s {
            return Err(Error::bad_input(format!(
                "advance_to {t} is before current time {}",
                self.time_s
            )));
        }
        if t == self.time_s {
            return Ok(());
        }
        self.pump(t);
        self.set_time(t);
        Ok(())
    }

    fn start_at(&mut self, t: f64) -> Result<(), Error> {
        Self::check_time(t)?;
        self.need_place()?;
        self.reap();
        let was_load = self.job.as_ref().is_some_and(|j| j.kind == Kind::Load);
        self.cancel_job();
        self.sh.advance_fs(t - self.time_s);
        self.set_time(t);
        if self.sh.state() == State::Loading {
            // прерванная задача не подала ничего: состояние вернёт новая
            self.sh.set_state(State::Ready, 1.0, "");
        }
        self.cond_t = t;
        if self.failed {
            return Ok(());
        }
        let (Some(cond), Some(Ok(inputs)), Ok(cfg)) =
            (self.cond.clone(), self.inputs.clone(), self.cfg_ok())
        else {
            return Ok(());
        };
        let want = CondRec::new(&inputs, &cond, hour_at(&cond, t));
        if self.cur.is_none() || was_load {
            self.launch(Kind::Load, want, t);
        } else if needs_recompute(self.cur.as_ref(), &want, cfg.step_min).is_some() {
            let rec = CondRec {
                hour: slot_hour(want.hour, cfg.step_min),
                ..want
            };
            self.launch(Kind::Start, rec, t);
        }
        Ok(())
    }

    fn status(&self) -> Status {
        Status {
            state: self.sh.state(),
            progress: f32::from_bits(self.sh.progress.load(Ordering::Relaxed)),
            time_s: f64::from_bits(self.sh.time_bits.load(Ordering::SeqCst)),
            reason: lock(&self.sh.reason).clone(),
        }
    }

    fn sample_many(&self, pts: &[[f32; 3]], _mode: SampleMode, out: &mut [[f32; 4]]) {
        let n = pts.len().min(out.len());
        let pb = self.sh.snapshot();
        let (pts, out) = (&pts[..n], &mut out[..n]);
        if n <= 512 {
            for (o, p) in out.iter_mut().zip(pts) {
                *o = sample_point(&pb, *p);
            }
        } else {
            out.par_chunks_mut(256)
                .zip(pts.par_chunks(256))
                .for_each(|(o, p)| {
                    for (o, p) in o.iter_mut().zip(p) {
                        *o = sample_point(&pb, *p);
                    }
                });
        }
    }

    fn cloud_density_many(&self, pts: &[[f32; 3]], out: &mut [f32]) {
        out.iter_mut().zip(pts).for_each(|(o, _)| *o = 0.0);
    }

    fn cloudbase_msl(&self) -> f32 {
        0.0
    }

    fn background_wind(&self, heights: &[f32], out: &mut [[f32; 2]]) {
        out.iter_mut().zip(heights).for_each(|(o, _)| *o = [0.0; 2]);
    }

    fn weather_json(&self) -> String {
        "{}".into()
    }

    fn weather_version(&self) -> (u64, u64) {
        (0, 0)
    }

    fn sun_state(&self) -> [f32; 4] {
        match self.sun {
            Some(d) => [d[0], d[1], d[2], 0.0],
            None => [0.0; 4],
        }
    }

    fn cores(&self, _center: [f32; 3], _radius: f32, out: &mut Vec<Core>) {
        out.clear();
    }

    fn clouds(&self, _center: [f32; 3], _radius: f32, out: &mut Vec<Cloud>) {
        out.clear();
    }

    fn cloud_raster(&self) -> Option<Arc<Raster>> {
        None
    }

    fn wave_crests(&self, _c: [f32; 2], _r: f32, _min_eta: f32, _sp: f32, out: &mut Vec<Crest>) {
        out.clear();
    }

    fn decompose(&self, p: [f32; 3]) -> Decomposition {
        let pb = self.sh.snapshot();
        let v = sample_point(&pb, p);
        Decomposition {
            names: vec!["field".into()],
            vel: vec![[v[0], v[1], v[2]]],
            sigma: vec![0.0],
            total: v,
        }
    }

    fn debug_raster(&self, _name: &str) -> Option<Arc<Raster>> {
        None
    }

    fn debug_raster_names(&self) -> Vec<String> {
        Vec::new()
    }
}
