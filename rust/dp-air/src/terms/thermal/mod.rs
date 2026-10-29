//! Слагаемое `thermal` (RW-10b): термики по клеткам сетки, повёрнутой по ветру; статичные
//! термики; профиль подъёма и опрос; фоновое опускание (в `sum`); описания ядер W6.
//!
//! Это путь «клеток» GDScript (`ThermalField._spawn`, синтетика и места без поля). Источники
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

use super::slots::{Thermal, ThermalOut};
use super::{Ctx, Terms};
use crate::Core;
use crate::field::runtime::ground_height;
use crate::place::Place;
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
    state: State,
    /// Адрес `Configs`, из которых разобран конфиг (смена — разбор заново).
    configs_ptr: usize,
    ground_ref: f64,
    statics: Vec<[f32; 4]>,
    statics_mode: u8,
}

/// Слот `Thermal`: термики по клеткам и статичные.
pub struct ThermalSlot {
    ground: Arc<dyn GroundSource>,
    hooks: Arc<dyn CloudHooks>,
    built: Option<Built>,
    /// Слот без земли (по умолчанию): набор не строится, `sample` даёт `None` (ни термиков, ни
    /// фонового опускания) - ветер остальных слагаемых не меняется.
    inert: bool,
}

impl ThermalSlot {
    /// Слот над землёй `ground`, без снимка (термиков нет, пока не вызван `advance`/`start_at`).
    pub fn new(ground: Arc<dyn GroundSource>) -> Self {
        ThermalSlot {
            ground,
            hooks: Arc::new(NoClouds),
            built: None,
            inert: false,
        }
    }

    /// Слот по умолчанию: земли нет, термиков и фона нет (пока не вызван `set_thermal_ground`).
    pub fn empty() -> Self {
        ThermalSlot {
            inert: true,
            ..Self::new(Arc::new(NoGround))
        }
    }

    /// Подключить облачные зацепки (RW-11).
    pub fn with_hooks(mut self, hooks: Arc<dyn CloudHooks>) -> Self {
        self.hooks = hooks;
        self
    }

    pub fn ground(&self) -> &Arc<dyn GroundSource> {
        &self.ground
    }

    /// Снимок набора (для RW-11: термики с `is_cb`, `has_cloud`, `top`, `lean`, `drift_vel`).
    pub fn state(&self) -> Option<&State> {
        self.built.as_ref().map(|b| &b.state)
    }

    pub fn setup(&self) -> Option<&Arc<Setup>> {
        self.built.as_ref().map(|b| &b.setup)
    }

    /// Новый снимок на момент `t` (или `None` — прежний ещё годится). `force` — `start_at`.
    pub fn rebuild(&self, terms: &Terms, t: f64, force: bool) -> Option<ThermalSlot> {
        if self.inert {
            return None;
        }
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
        let focus = terms
            .focuses
            .first()
            .map_or([0.0, 0.0], |f| [f64::from(f.pos[0]), f64::from(f.pos[2])]);
        let setup = Setup::new(terms, cfg, ground_ref);
        let same = prev.is_some_and(|b| b.setup.same_env(&setup));
        if !force
            && same
            && let Some(b) = prev
            && b.state.slot == slot
            && b.statics == terms.statics
            && b.statics_mode == terms.statics_mode
        {
            return None;
        }
        let memo = match prev {
            Some(b) if same => b.memo.clone(),
            _ => Arc::new(Mutex::new(Memo::new())),
        };
        let setup = Arc::new(setup);
        let mut all = statics::build_statics(&setup, &*self.ground, &terms.statics);
        if !setup.static_only {
            let mut m = memo.lock().unwrap_or_else(|e| e.into_inner());
            m.prune(t);
            setup.generate(&mut m, &*self.ground, &*self.hooks, t, focus, &mut all);
        }
        let state = State::build(&setup, all, t, focus, dt, slot);
        Some(ThermalSlot {
            ground: self.ground.clone(),
            hooks: self.hooks.clone(),
            inert: false,
            built: Some(Built {
                setup,
                memo,
                state,
                configs_ptr: ptr,
                ground_ref,
                statics: terms.statics.clone(),
                statics_mode: terms.statics_mode,
            }),
        })
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

impl Thermal for ThermalSlot {
    fn sample(&self, c: &Ctx) -> Option<ThermalOut> {
        let b = self.built.as_ref()?;
        let o = b.state.sample(&b.setup, &*self.hooks, c.pos, c.t);
        Some(ThermalOut {
            w: o[0],
            mask: o[1],
            sigma: o[2],
        })
    }

    fn advanced(&self, terms: &Terms, t: f64, force: bool) -> Option<Arc<dyn Thermal>> {
        self.rebuild(terms, t, force)
            .map(|s| Arc::new(s) as Arc<dyn Thermal>)
    }

    fn cores(&self, center: [f32; 3], radius: f32, t: f64, out: &mut Vec<Core>) {
        ThermalSlot::cores(self, center, radius, t, out);
    }

    fn as_slot(&self) -> Option<&ThermalSlot> {
        Some(self)
    }
}
