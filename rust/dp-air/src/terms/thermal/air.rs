//! Источники термиков из поля в жизни термиков (RW-10e): сборка `AirThermals` по самому грубому
//! уровню поля, рождение термика источника (`ThermalField._spawn_air`), охват поля (`covers`).
//!
//! Сила источника и вода — от [`GroundSource`] (в `pick_in_column` — на момент сборки), высота —
//! оттуда же; `u10` (ветер прогноза на 10 м для `u*`) приходит параметром (в `FieldMeta` его нет).
use super::cells::{AIR_IA, Setup};
use super::life::{AtmoThermal, pair};
use super::{CloudHooks, GroundSource};
use crate::field::wind_field::Field;
use crate::rand::Pcg32;
use crate::terms::thermal_air::{
    AirThermals, AirThermalsCfg, BuildIn, FillWeather, PickGround, has_inputs, pick_in_column,
    signature,
};
use serde_json::Value;
use std::sync::Arc;

/// Собранные источники и уровень поля, по которому они собраны.
#[derive(Clone)]
pub struct AirSrc {
    pub src: Arc<AirThermals>,
    pub level: Arc<Field>,
}

impl std::fmt::Debug for AirSrc {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "AirSrc({} источников)", self.src.count())
    }
}

impl AirSrc {
    /// Точка (x, z) там, где термики берутся из поля (вес края уровня ≥ ½).
    pub fn covers(&self, x: f64, z: f64) -> bool {
        self.src.covers(&self.level, [x, z])
    }
}

/// Ключ сборки: уровень поля и входы, от которых зависят источники (`_air_key`, `_air_inputs`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AirKey {
    pub level: usize,
    pub cloudbase_msl: f64,
    pub duty: f64,
    pub sun: [f64; 3],
}

impl AirKey {
    /// `None` — поля нет или в нём нет нужного (`has_inputs`): источников нет.
    pub fn of(level: Option<&Arc<Field>>, setup: &Setup) -> Option<AirKey> {
        let f = level.filter(|f| has_inputs(f))?;
        Some(AirKey {
            level: Arc::as_ptr(f) as usize,
            cloudbase_msl: setup.cloudbase_msl,
            duty: setup.w.f64_or("thermal_duty", 0.0),
            sun: setup.sun,
        })
    }
}

/// Сила источника и вода на момент сборки.
struct PickAdapter<'a> {
    g: &'a dyn GroundSource,
    t: f64,
}

impl PickGround for PickAdapter<'_> {
    fn sun(&self, x: f64, z: f64) -> f64 {
        self.g.source(x, z, self.t)
    }
    fn is_water(&self, x: f64, z: f64) -> bool {
        self.g.is_water(x, z)
    }
}

/// Доля суши столбцов прежней сборки той же сетки: `(подпись, значения)`.
pub type LandCache = Option<(String, Arc<Vec<f32>>)>;

/// Всё, что нужно сборке источников (владеющее: уходит в фоновую задачу).
pub struct AirBuild {
    pub level: Arc<Field>,
    pub ground: Arc<dyn GroundSource>,
    /// Секция `thermal` конфига секция `atmosphere`.
    pub thermal: Value,
    pub key: AirKey,
    pub u10: f64,
    pub seed: u64,
    /// Момент сборки: на него берётся сила источника в `pick_in_column`.
    pub t: f64,
    pub land: LandCache,
}

impl AirBuild {
    /// Построить источники (`AirThermals.build`); `None` — нет входа.
    pub fn run(&self) -> Option<AirSrc> {
        let cfg =
            AirThermalsCfg::from_thermal(&self.thermal, self.key.duty, self.key.cloudbase_msl);
        let g = *self.level.grid();
        let pg = PickAdapter {
            g: &*self.ground,
            t: self.t,
        };
        let cand = cfg.source_candidates;
        let seed = self.seed;
        let pick = move |i: usize, j: usize| pick_in_column(i, j, &g, Some(&pg), seed, cand);
        let height = |x: f64, z: f64| self.ground.height(x, z);
        let water = |x: f64, z: f64| self.ground.is_water(x, z);
        let mut inp = BuildIn::new(&cfg, self.u10);
        inp.height_fn = Some(&height);
        inp.pick_fn = Some(&pick);
        inp.water_fn = Some(&water);
        let sig = signature(&self.level);
        if let Some((s, l)) = &self.land
            && *s == sig
        {
            inp.land = Some(l.as_slice());
        }
        let src = AirThermals::build(&self.level, &inp)?;
        Some(AirSrc {
            src: Arc::new(src),
            level: self.level.clone(),
        })
    }
}

/// Погода для `fill`.
pub fn fill_weather(setup: &Setup) -> FillWeather {
    let w = &setup.w;
    let ext = w
        .get("thermal_extreme_ms")
        .and_then(|v| v.as_array())
        .filter(|a| a.len() == 2)
        .map(|a| [a[0].as_f64().unwrap_or(0.0), a[1].as_f64().unwrap_or(0.0)]);
    FillWeather {
        radius_max: pair(w, "thermal_radius_m", [0.0, 0.0])[1],
        extreme_chance: w.f64_or("thermal_extreme_chance", 0.0),
        extreme_ms: ext,
    }
}

impl Setup {
    /// Термик источника поля (столбец `j = ia − AIR_IA`, `i = ic`): точка, сила, потолок и снос —
    /// из `AirThermals`; доля циклов, радиус, жизнь, Cb, крайние — как у клетки. Порядок чисел
    /// генератора буквально как `_spawn_air`. Потолок частицы ниже кромки — сухой термик.
    pub(super) fn spawn_air(
        &self,
        ia: i64,
        ic: i64,
        id: i64,
        t_start: f64,
        period: f64,
        hooks: &dyn CloudHooks,
    ) -> Option<AtmoThermal> {
        let air = self.air.as_ref()?;
        let s = air.src.index_of(ic as usize, (ia - AIR_IA) as usize)?;
        let w = &self.w;
        let cfg = &self.cfg;
        let mut rng = Pcg32::from_seed(id as u64);
        // облачность неба уже в потоке тепла поля: доля циклов без неё
        let duty = w.f64_or("thermal_duty", 0.0) / w.f64_or("sky_duty_k", 1.0).max(0.01);
        if f64::from(rng.randf()) > duty {
            return None;
        }
        let mut th = AtmoThermal::blank(id);
        th.noise_seed = id;
        th.cell = (ia, ic);
        let fill = air
            .src
            .fill(s, &mut rng, &fill_weather(self), self.cloudbase_msl);
        if fill.kind < 0 {
            return None;
        }
        th.src = fill.src;
        th.top = fill.top;
        th.strength = fill.strength;
        th.ring = fill.ring;
        th.radius = fill.radius;
        th.set_life(cfg, &mut rng, t_start, period);
        let shade = hooks.shade_at(f64::from(th.src[0]), f64::from(th.src[2]), self.sun)
            * cfg.cloud_shade_factor;
        th.strength *= 1.0 - shade;
        let r1 = f64::from(rng.randf());
        th.setup_cloud(w, r1);
        let r2 = f64::from(rng.randf());
        th.setup_cb(cfg, w, r2);
        if f64::from(air.src.top[s]) < self.cloudbase_msl - 1.0 {
            th.has_cloud = false;
            th.is_cb = false;
        }
        th.apply_wind(cfg, &self.wind, self.street, Some(air.src.drift[s]));
        Some(th)
    }
}
