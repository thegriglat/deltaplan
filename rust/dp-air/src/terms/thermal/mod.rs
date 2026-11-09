//! Слагаемое `thermal` (RW-10b): термики по клеткам сетки, повёрнутой по ветру; статичные
//! термики; профиль подъёма и опрос; фоновое опускание (в `sum`); описания ядер W6.
//!
//! Это путь «клеток» эталона (`ThermalField._spawn`, синтетика и места без поля). Источники
//! из поля воздуха (`_spawn_air`, `AirThermals`) — RW-10d/10e; сила источника на сетке — через
//! [`GroundSource`] (RW-10c даёт реализацию для места); облачные зацепки (подсос, тень облака
//! на источнике) — через [`CloudHooks`], нулевые до RW-11.
//!
//! ## Состояние во времени
//! Слот `Terms.slots.thermal` — [`ThermalSlot`]: неизменяемый снимок набора термиков на момент
//! обновления (раз в `thermal.refresh_interval_s` атмосферы). Снимок строит `Terms::advance(t)`
//! / `Terms::start_at(t)` через [`Thermal::advanced`] и подменяет слот целиком (читатели держат
//! прежний). Опрос в момент `c.t` считает огибающую и снос термиков аналитически, поэтому между
//! обновлениями (до `margin = refresh_interval_s`) ответы точны. Термик цикла — чистая функция
//! (клетка, цикл), поэтому `start_at(t)` равно прогону с 0 (W2): память о циклах ([`Memo`]) —
//! только кеш.
//!
//! Подключение места: `Terms::set_thermal_ground(Arc<dyn GroundSource>)` (до этого — плоская
//! земля без источников, термиков нет).
pub mod air;
pub mod bubble;
pub mod bubble_kbar;
pub mod bubble_q;
pub mod cells;
pub mod cfg;
pub mod cores;
pub mod life;
pub mod profile;
pub mod sample;
pub mod statics;

pub use cells::{Memo, Setup, mean_height};
pub use cfg::ThermalCfg;
pub use life::AtmoThermal;
pub use sample::State;

use super::clouds::CloudPhysics;
use super::slots::{Thermal, ThermalOut};
use super::{Ctx, Terms};
use crate::Core;
use crate::field::runtime::ground_height;
use crate::place::Place;
use air::{AirBuild, AirKey, AirSrc, LandCache};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Земля под термиками: высота, вода, сила источника.
pub trait GroundSource: Send + Sync {
    /// Высота рельефа в `(x, z)`, м.
    fn height(&self, x: f64, z: f64) -> f64;
    /// Над водой источника термика нет.
    fn is_water(&self, _x: f64, _z: f64) -> bool {
        false
    }
    /// Сила источника в `(x, z)` в момент `t`, 0..1 (`ground.sun` / `AtmoDay.source_at`).
    fn source(&self, x: f64, z: f64, t: f64) -> f64;
}

/// Плоская земля без источников: термики не рождаются (слот по умолчанию).
pub struct NoGround;
impl GroundSource for NoGround {
    fn height(&self, _x: f64, _z: f64) -> f64 {
        0.0
    }
    fn source(&self, _x: f64, _z: f64, _t: f64) -> f64 {
        0.0
    }
}

/// Сила источника в `(x, z, t)`.
pub type SourceFn = dyn Fn(f64, f64, f64) -> f64 + Send + Sync;

/// Земля из места W5: высота билинейно по растру, вода — ближайший узел `water`, сила
/// источника — функция снаружи (RW-10c).
pub struct PlaceGround {
    place: Arc<Place>,
    source: Arc<SourceFn>,
}

impl PlaceGround {
    pub fn new(place: Arc<Place>, source: Arc<SourceFn>) -> Self {
        PlaceGround { place, source }
    }
}

impl GroundSource for PlaceGround {
    fn height(&self, x: f64, z: f64) -> f64 {
        f64::from(ground_height(&self.place, x as f32, z as f32))
    }
    fn is_water(&self, x: f64, z: f64) -> bool {
        let g = &self.place.header().grid;
        let (w, h) = (g.width as i64, g.height as i64);
        let i = (((x - g.origin_x) / g.spacing).round() as i64).clamp(0, w - 1);
        let j = (((z - g.origin_z) / g.spacing).round() as i64).clamp(0, h - 1);
        self.place.water()[(j * w + i) as usize] != 0
    }
    fn source(&self, x: f64, z: f64, t: f64) -> f64 {
        (self.source)(x, z, t)
    }
}

/// Облачные зацепки термиков (петля термики ↔ облака, RW-11). Нулевая реализация — по умолчанию.
pub trait CloudHooks: Send + Sync {
    /// Доля прямого солнца, закрытая облаками над точкой земли (`CloudField.shade_at`), 0..1.
    fn shade_at(&self, _x: f64, _z: f64, _sun: [f64; 3]) -> f64 {
        0.0
    }
    /// Подсос в момент `t`: `(усиление подъёма у основания, высота потока в облаке, м)`.
    fn suck(&self, th: &AtmoThermal, _t: f64) -> [f64; 2] {
        [th.suck, 0.0]
    }
}

/// Облаков нет: тень 0, подсос `th.suck`.
pub struct NoClouds;
impl CloudHooks for NoClouds {}

/// Собранное на момент обновления.
struct Built {
    setup: Arc<Setup>,
    memo: Arc<Mutex<Memo>>,
    state: Arc<State>,
    /// Адрес `Configs`, из которых разобран конфиг (смена — разбор заново).
    configs_ptr: usize,
    ground_ref: f64,
    statics: Vec<[f32; 4]>,
    statics_mode: u8,
    /// Источники поля и ключ, с которым они собраны.
    air: Option<(AirKey, AirSrc)>,
    /// Доля суши столбцов последней сборки (кеш на сетку места).
    land: LandCache,
    /// Кеш таблиц шаблона пузыря, общий для пересборок при том же окружении.
    bubbles: Arc<bubble::BubbleCache>,
}

/// Результат фоновой пересборки.
struct Cell {
    done: AtomicBool,
    val: Mutex<Option<ThermalSlot>>,
}

/// Фоновая пересборка (одна за раз), общая для снимков слота.
#[derive(Default)]
struct Job(Mutex<Option<Arc<Cell>>>);

/// Слот `Thermal`: термики по клеткам, источники из поля и статичные.
pub struct ThermalSlot {
    ground: Arc<dyn GroundSource>,
    /// Своя реализация зацепок (тесты): вместо облаков `Terms`.
    hooks: Option<Arc<dyn CloudHooks>>,
    /// Облака, как их видели термики на последнем `advance` (RW-10f): подсос и тень берутся из
    /// них, а не из «текущих» облаков. GD пишет параметры термиков (`_write_params`, подсос) в
    /// `update_time` каждого шага по физике облаков до их обновления; после `start_at` - до
    /// облаков вообще (`refresh_now`: термики, затем `cloud_phys.refresh`). `None` - облаков нет.
    cloud: Option<Arc<CloudPhysics>>,
    built: Option<Built>,
    /// Слот без земли (по умолчанию): набор не строится, `sample` даёт `None` (ни термиков, ни
    /// фонового опускания) - ветер остальных слагаемых не меняется.
    inert: bool,
    job: Arc<Job>,
}

/// Что нужно знать о текущем состоянии `Terms`, чтобы решить, годится ли снимок.
struct Plan {
    setup: Setup,
    same: bool,
    slot: i64,
    key: Option<AirKey>,
    dt: f64,
    cfg_ptr: usize,
    ground_ref: f64,
}

impl ThermalSlot {
    /// Слот над землёй `ground`, без снимка (термиков нет, пока не вызван `advance`/`start_at`).
    pub fn new(ground: Arc<dyn GroundSource>) -> Self {
        ThermalSlot {
            ground,
            hooks: None,
            cloud: None,
            built: None,
            inert: false,
            job: Arc::new(Job::default()),
        }
    }

    /// Слот по умолчанию: земли нет, термиков и фона нет (пока не вызван `set_thermal_ground`).
    pub fn empty() -> Self {
        ThermalSlot {
            inert: true,
            ..Self::new(Arc::new(NoGround))
        }
    }

    /// Подставить свои облачные зацепки вместо облаков `Terms` (тесты).
    pub fn with_hooks(mut self, hooks: Arc<dyn CloudHooks>) -> Self {
        self.hooks = Some(hooks);
        self
    }

    pub fn ground(&self) -> &Arc<dyn GroundSource> {
        &self.ground
    }

    /// Снимок набора (для RW-11: термики с `is_cb`, `has_cloud`, `top`, `lean`, `drift_vel`).
    pub fn state(&self) -> Option<&State> {
        self.built.as_ref().map(|b| &*b.state)
    }

    pub fn setup(&self) -> Option<&Arc<Setup>> {
        self.built.as_ref().map(|b| &b.setup)
    }

    /// Средняя высота земли вокруг (0, 0) (`Atmosphere._ground_ref`): отсчёт кромки облаков и
    /// фонового ветра. Снимок собран — его значение, иначе считается по `cfg` (`ground.reference_*`).
    pub fn ground_ref(&self, cfg: &ThermalCfg) -> f64 {
        match &self.built {
            Some(b) => b.ground_ref,
            None => mean_height(&*self.ground, cfg),
        }
    }

    /// Источники из поля, по которым собран снимок.
    pub fn air(&self) -> Option<&AirSrc> {
        self.built
            .as_ref()
            .and_then(|b| b.air.as_ref())
            .map(|a| &a.1)
    }

    /// Идёт ли фоновая пересборка.
    pub fn pending(&self) -> bool {
        self.job
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_some()
    }

    /// Дождаться фоновой пересборки (тесты); `false` — вышло время.
    pub fn wait_pending(&self, limit: std::time::Duration) -> bool {
        let c = self.job.0.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let Some(c) = c else { return true };
        let t0 = std::time::Instant::now();
        while !c.done.load(Ordering::Acquire) {
            if t0.elapsed() > limit {
                return false;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        true
    }

    fn plan(&self, terms: &Terms, t: f64) -> Plan {
        let ptr = Arc::as_ptr(&terms.configs) as usize;
        let prev = self.built.as_ref();
        let (cfg, ground_ref) = match prev {
            Some(b) if b.configs_ptr == ptr => (b.setup.cfg.clone(), b.ground_ref),
            _ => {
                let cfg = ThermalCfg::from_configs(&terms.configs);
                let gr = mean_height(&*self.ground, &cfg);
                (cfg, gr)
            }
        };
        let dt = cfg.refresh_interval_s.max(1.0e-3);
        let slot = (t / dt).floor() as i64;
        let mut setup = Setup::new(terms, cfg, ground_ref);
        let key = AirKey::of(terms.air.as_ref(), &setup);
        // сравнивать окружение надо с теми же источниками, что и у прежнего снимка
        setup.air = prev.and_then(|b| b.air.as_ref()).map(|a| a.1.clone());
        let same = prev.is_some_and(|b| b.setup.same_env(&setup));
        Plan {
            setup,
            same,
            slot,
            key,
            dt,
            cfg_ptr: ptr,
            ground_ref,
        }
    }

    /// Прежний снимок ещё годится (тот же час обновления, окружение, статичные и источники).
    fn is_current(&self, terms: &Terms, p: &Plan) -> bool {
        let Some(b) = &self.built else { return false };
        p.same
            && b.state.slot == p.slot
            && b.statics == terms.statics
            && b.statics_mode == terms.statics_mode
            && b.air.as_ref().map(|a| a.0) == p.key
    }

    /// Новый снимок на момент `t` (или `None` — прежний ещё годится), синхронно. `force` —
    /// `start_at`: строить заново. Если нужны источники поля, их собирает тоже тут.
    pub fn rebuild(&self, terms: &Terms, t: f64, force: bool) -> Option<ThermalSlot> {
        // `start_at` как в эталоне (`refresh_now`): термики строятся раньше облаков - без подсоса и тени
        let cloud = if force {
            None
        } else {
            Some(terms.cloud_physics().clone())
        };
        if self.inert {
            return None;
        }
        let mut p = self.plan(terms, t);
        if !force && self.is_current(terms, &p) {
            return None;
        }
        let prev = self.built.as_ref();
        let memo = match prev {
            Some(b) if p.same => b.memo.clone(),
            _ => Arc::new(Mutex::new(Memo::new())),
        };
        // источники поля: прежние, если ключ тот же, иначе сборка (первые — ждём, как GD)
        let mut land: LandCache = prev.and_then(|b| b.land.clone());
        let air = match p.key {
            None => None,
            Some(k) => match prev.and_then(|b| b.air.as_ref()) {
                Some(a) if a.0 == k => Some(a.clone()),
                old => {
                    let level = terms.air.clone()?;
                    let b = AirBuild {
                        level: level.clone(),
                        ground: self.ground.clone(),
                        thermal: crate::terms::named_json(&terms.configs, "atmosphere")
                            .and_then(|v| v.get("thermal").cloned())
                            .unwrap_or(serde_json::Value::Null),
                        key: k,
                        u10: terms.air_u10(),
                        seed: terms.seed,
                        t,
                        land: land.clone(),
                        count_by_cycle: terms.air_count_by_cycle,
                    };
                    let built = b.run();
                    if let Some(a) = &built
                        && !a.src.land.is_empty()
                    {
                        land = Some((a.src.grid_sig.clone(), Arc::new(a.src.land.clone())));
                    }
                    // прежние циклы источников помнили старый список — забыть (живые доживают)
                    {
                        let mut m = memo.lock().unwrap_or_else(|e| e.into_inner());
                        let same_cover = old.is_some_and(|o| {
                            crate::terms::thermal_air::same_cover(&o.1.level, &level)
                        });
                        m.clear_empty(same_cover);
                    }
                    built.map(|a| (k, a))
                }
            },
        };
        if p.key.is_some() && air.is_none() && prev.and_then(|b| b.air.as_ref()).is_some() {
            memo.lock()
                .unwrap_or_else(|e| e.into_inner())
                .clear_empty(false);
        }
        p.setup.air = air.as_ref().map(|a| a.1.clone());
        let setup = Arc::new(p.setup);
        let focuses = focus_points(terms);
        let mut all = statics::build_statics(&setup, &*self.ground, &terms.statics);
        if !setup.static_only {
            let mut m = memo.lock().unwrap_or_else(|e| e.into_inner());
            m.prune(t);
            setup.generate(
                &mut m,
                &*self.ground,
                self.hooks_of(cloud.as_ref()),
                t,
                &focuses,
                &mut all,
            );
        }
        let bubbles = match prev {
            Some(b) if p.same => b.bubbles.clone(),
            _ => Arc::new(bubble::BubbleCache::default()),
        };
        // `start_at` (force) синхронный: таблиц не строит, профиль до первого фонового обновления
        let state =
            State::build_cached(&setup, all, t, &focuses, p.dt, p.slot, &bubbles, !force);
        Some(ThermalSlot {
            ground: self.ground.clone(),
            hooks: self.hooks.clone(),
            cloud,
            inert: false,
            job: self.job.clone(),
            built: Some(Built {
                setup,
                memo,
                state: Arc::new(state),
                configs_ptr: p.cfg_ptr,
                ground_ref: p.ground_ref,
                statics: terms.statics.clone(),
                statics_mode: terms.statics_mode,
                air,
                land,
                bubbles,
            }),
        })
    }

    /// Ход `Terms::advance`: пересборка в фоне (снимок публикуется по готовности), пока есть
    /// прежний снимок; первый снимок и источники, которых ещё не было, — синхронно.
    fn advance_bg(&self, terms: &Terms, t: f64) -> Option<ThermalSlot> {
        if self.inert {
            return None;
        }
        // готовый результат принять, если он ещё про те же входы
        let done = {
            let mut g = self.job.0.lock().unwrap_or_else(|e| e.into_inner());
            match g.as_ref() {
                Some(c) if c.done.load(Ordering::Acquire) => {
                    let c = g.take();
                    c.and_then(|c| c.val.lock().unwrap_or_else(|e| e.into_inner()).take())
                }
                _ => None,
            }
        };
        if let Some(res) = done {
            let p = res.plan(terms, t);
            let b = res.built.as_ref();
            let ok = b.is_some_and(|b| {
                p.same
                    && b.statics == terms.statics
                    && b.statics_mode == terms.statics_mode
                    && b.air.as_ref().map(|a| a.0) == p.key
            });
            if ok {
                return Some(res);
            }
        }
        let p = self.plan(terms, t);
        // всё тяжёлое (первая сборка, источники поля) - в фоне: главный поток не ждёт (RW-12v);
        // синхронно строит только `start_at` (`force`)
        if self.is_current(terms, &p) {
            return None;
        }
        let mut g = self.job.0.lock().unwrap_or_else(|e| e.into_inner());
        if g.is_some() {
            return None;
        }
        let cell = Arc::new(Cell {
            done: AtomicBool::new(false),
            val: Mutex::new(None),
        });
        *g = Some(cell.clone());
        drop(g);
        let me = self.snapshot();
        let terms = terms.clone();
        rayon::spawn(move || {
            let r = me.rebuild(&terms, t, false);
            *cell.val.lock().unwrap_or_else(|e| e.into_inner()) = r;
            cell.done.store(true, Ordering::Release);
        });
        None
    }

    /// Зацепки: свои или переданные облака (нет облаков - нулевые).
    fn hooks_of<'a>(&'a self, cloud: Option<&'a Arc<CloudPhysics>>) -> &'a dyn CloudHooks {
        match (&self.hooks, cloud) {
            (Some(h), _) => &**h,
            (None, Some(c)) => &**c,
            (None, None) => &NoClouds,
        }
    }

    /// Облака изменились настолько, что подсос или тень могли поменяться (условие публикации
    /// `Terms::advance_clouds`: поле шагнуло - в том числе при смене конфига - или есть Cb-объекты).
    fn cloud_changed(&self, now: &Arc<CloudPhysics>) -> bool {
        if self.hooks.is_some() || self.built.is_none() {
            return false;
        }
        match &self.cloud {
            None => true,
            Some(a) => a.version != now.version || a.objects.count > 0 || now.objects.count > 0,
        }
    }

    /// Тот же набор термиков с облаками `c` (подсос и тень видят новые облака).
    fn with_cloud(&self, c: Arc<CloudPhysics>) -> ThermalSlot {
        ThermalSlot {
            ground: self.ground.clone(),
            hooks: self.hooks.clone(),
            cloud: Some(c),
            inert: self.inert,
            job: self.job.clone(),
            built: self.built.as_ref().map(|b| Built {
                setup: b.setup.clone(),
                memo: b.memo.clone(),
                state: b.state.clone(),
                configs_ptr: b.configs_ptr,
                ground_ref: b.ground_ref,
                statics: b.statics.clone(),
                statics_mode: b.statics_mode,
                air: b.air.clone(),
                land: b.land.clone(),
                bubbles: b.bubbles.clone(),
            }),
        }
    }

    /// Копия ручки снимка (общие `Arc`): для фоновой задачи.
    fn snapshot(&self) -> ThermalSlot {
        ThermalSlot {
            ground: self.ground.clone(),
            hooks: self.hooks.clone(),
            cloud: self.cloud.clone(),
            inert: self.inert,
            job: self.job.clone(),
            built: self.built.as_ref().map(|b| Built {
                setup: b.setup.clone(),
                memo: b.memo.clone(),
                state: Arc::new(State::stub(b.state.slot)),
                configs_ptr: b.configs_ptr,
                ground_ref: b.ground_ref,
                statics: b.statics.clone(),
                statics_mode: b.statics_mode,
                air: b.air.clone(),
                land: b.land.clone(),
                bubbles: b.bubbles.clone(),
            }),
        }
    }

    /// Все термики набора в радиусе (без фильтра активности и силы), см. [`cores::all_cores`].
    pub fn all_cores(&self, center: [f32; 3], radius: f32, t: f64, out: &mut Vec<Core>) {
        out.clear();
        if let Some(b) = &self.built {
            cores::all_cores(&b.state, center, radius, t, out);
        }
    }

    /// Ядра W6 на момент `t` (`Atmosphere.cores`); `out` очищается.
    pub fn cores(&self, center: [f32; 3], radius: f32, t: f64, out: &mut Vec<Core>) {
        out.clear();
        if let Some(b) = &self.built {
            cores::cores(&b.state, center, radius, t, out);
        }
    }
}

/// Точки фокусов (x, z); нет фокусов — начало координат, как в эталоне.
fn focus_points(terms: &Terms) -> Vec<[f64; 2]> {
    let v: Vec<[f64; 2]> = terms
        .focuses
        .iter()
        .map(|f| [f64::from(f.pos[0]), f64::from(f.pos[2])])
        .collect();
    if v.is_empty() { vec![[0.0, 0.0]] } else { v }
}

impl Thermal for ThermalSlot {
    fn sample(&self, c: &Ctx) -> Option<ThermalOut> {
        let b = self.built.as_ref()?;
        let hooks = self.hooks_of(self.cloud.as_ref());
        let (mut o, uh) = b.state.sample_bubble(&b.setup, hooks, c.pos, c.t);
        if let Some(a) = &b.air {
            o = a.1.src.with_between(c.fs, c.pos, o);
        }
        Some(ThermalOut {
            w: o[0],
            mask: o[1],
            sigma: o[2],
            uh,
        })
    }

    fn advanced(&self, terms: &Terms, t: f64, force: bool) -> Option<Arc<dyn Thermal>> {
        let r = if force || !terms.thermal_async {
            self.rebuild(terms, t, force)
        } else {
            self.advance_bg(terms, t)
        };
        r.map(|s| Arc::new(s) as Arc<dyn Thermal>)
    }

    fn synced_with_clouds(&self, terms: &Terms) -> Option<Arc<dyn Thermal>> {
        let now = terms.cloud_physics();
        self.cloud_changed(now)
            .then(|| Arc::new(self.with_cloud(now.clone())) as Arc<dyn Thermal>)
    }

    fn cores(&self, center: [f32; 3], radius: f32, t: f64, out: &mut Vec<Core>) {
        ThermalSlot::cores(self, center, radius, t, out);
    }

    fn as_slot(&self) -> Option<&ThermalSlot> {
        Some(self)
    }
}
