//! Ход дня (`AtmoDay`, RW-12c): погода, солнце и сила источника как чистые функции времени атмосферы `t`.
//!
//! Час места `hour(t) = start_hour + (t − t0)·speed/3600`, зажатый в `time.min_hour…max_hour`
//! (`world.json`; после `max_hour` время стоит). Погода считается раз на шаг `quantum_h` часов
//! (кеш по номеру шага, не больше 512 записей) и между шагами интерполируется линейно.
use std::collections::HashMap;
use std::sync::Arc;

use serde_json::{Map, Value};

use super::climate::{ClimatePlace, PlaceCtx};
use super::derive::derive;
use crate::conditions::Forecast;
use crate::field::sun::{day_of_year, lerp, solar_position};
use crate::field::weather_core::WeatherModelCfg;

/// Погода как словарь GD (ключи пресета и `_derived`).
pub type WeatherMap = Map<String, Value>;
/// Час места -> погода (`AtmoDay.weather_fn`).
pub type WeatherFn = Box<dyn Fn(f64) -> WeatherMap + Send + Sync>;
/// (x, z, час места) -> сила источника термиков (`AtmoDay.source_fn`).
pub type SourceFn = Box<dyn Fn(f64, f64, f64) -> f64 + Send + Sync>;

/// Записей в кеше погоды, после которых он очищается (как GD: `size() > 512`).
const CACHE_MAX: usize = 512;

/// `world.json` → `time.*`, нужное ходу дня. Нет `world` — запасные значения GD
/// (`AtmoDay._init`, `Config.value`): 6, 20, 2°.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WorldTime {
    pub min_hour: f64,
    pub max_hour: f64,
    pub min_light_elevation_deg: f64,
}

impl Default for WorldTime {
    fn default() -> Self {
        WorldTime {
            min_hour: 6.0,
            max_hour: 20.0,
            min_light_elevation_deg: 2.0,
        }
    }
}

impl WorldTime {
    /// Из `world.json` целиком (`time.min_hour`, `time.max_hour`, `time.min_light_elevation_deg`).
    pub fn from_world(world: &Value) -> Self {
        let d = WorldTime::default();
        let g = |k: &str, def: f64| super::tables::num(world, &["time", k], def);
        WorldTime {
            min_hour: g("min_hour", d.min_hour),
            max_hour: g("max_hour", d.max_hour),
            min_light_elevation_deg: g("min_light_elevation_deg", d.min_light_elevation_deg),
        }
    }
}

/// Место и дата для направления на солнце. `utc_offset_h` — NaN: солнечное время.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SunSpec {
    pub lat: f64,
    pub lon: f64,
    pub month: i64,
    pub day: i64,
    pub utc_offset_h: f64,
}

/// `Vector3.normalized()` Godot: f32-арифметика, нулевой вектор остаётся нулевым.
pub(crate) fn normalized_f32(v: [f32; 3]) -> [f32; 3] {
    let l2 = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
    if l2 == 0.0 {
        return v;
    }
    let l = l2.sqrt();
    [v[0] / l, v[1] / l, v[2] / l]
}

/// Направление НА солнце в час `hour` (`AtmoDay.sun_direction`): высота не ниже
/// `min_light_elevation_deg`. Как в GD, азимут и высота `SunClock.solar_position` — `Vector2` (f32),
/// результат — `Vector3` (f32, нормализован в f32).
pub fn sun_direction(hour: f64, s: &SunSpec, min_light_elevation_deg: f64) -> [f32; 3] {
    let (az, el) = solar_position(
        s.lat,
        s.lon,
        day_of_year(s.month, s.day),
        hour,
        s.utc_offset_h,
    );
    let (az, el) = (az as f32 as f64, el as f32 as f64);
    let el = el.max(min_light_elevation_deg).to_radians();
    let az = az.to_radians();
    normalized_f32([
        (az.sin() * el.cos()) as f32,
        el.sin() as f32,
        (-az.cos() * el.cos()) as f32,
    ])
}

/// Ход дня. Погода — функция часа места; кеш по номеру шага.
pub struct AtmoDay {
    /// Час места при `t = t0`.
    pub start_hour: f64,
    /// Время атмосферы, с, которому соответствует `start_hour`.
    pub t0: f64,
    /// Скорость часов (сеть — всегда 1).
    pub speed: f64,
    /// Шаг пересчёта погоды, часы.
    pub quantum_h: f64,
    pub time: WorldTime,
    weather_fn: Option<WeatherFn>,
    sun: Option<SunSpec>,
    source_fn: Option<SourceFn>,
    cache: HashMap<i64, Arc<WeatherMap>>,
}

impl AtmoDay {
    /// День без погоды, солнца и источников (`AtmoDay.new()` с заданными часами).
    pub fn new(start_hour: f64, t0: f64, speed: f64, quantum_h: f64, time: WorldTime) -> Self {
        AtmoDay {
            start_hour,
            t0,
            speed,
            quantum_h,
            time,
            weather_fn: None,
            sun: None,
            source_fn: None,
            cache: HashMap::new(),
        }
    }

    /// День по прогнозу, как `Atmosphere._f_resolve`: погода часа — `derive` с шагом сетки источников
    /// `thermal_spacing_m` разгара дня (не меняется в течение дня), `overrides` поверх, без
    /// `static_thermals`. `climate` — [`climate_place`](super::climate_place) без `start_msl_m`.
    #[allow(clippy::too_many_arguments)]
    pub fn from_forecast(
        forecast: Forecast,
        ctx: PlaceCtx,
        climate: ClimatePlace,
        cfg: WeatherModelCfg,
        overrides: WeatherMap,
        start_hour: f64,
        t0: f64,
        speed: f64,
        quantum_h: f64,
        time: WorldTime,
    ) -> Self {
        let mut d = AtmoDay::new(start_hour, t0, speed, quantum_h, time);
        d.sun = Some(SunSpec {
            lat: ctx.lat,
            lon: ctx.lon,
            month: ctx.month,
            day: ctx.day,
            utc_offset_h: ctx.utc_offset_h,
        });
        d.weather_fn = Some(forecast_weather_fn(forecast, ctx, climate, cfg, overrides));
        d
    }

    pub fn with_weather_fn(mut self, f: WeatherFn) -> Self {
        self.weather_fn = Some(f);
        self.cache.clear();
        self
    }

    pub fn with_sun(mut self, s: SunSpec) -> Self {
        self.sun = Some(s);
        self
    }

    pub fn with_source_fn(mut self, f: SourceFn) -> Self {
        self.source_fn = Some(f);
        self
    }

    pub fn has_weather(&self) -> bool {
        self.weather_fn.is_some()
    }

    /// Час места в момент `t` (после `max_hour` время стоит, до `min_hour` — тоже).
    pub fn hour_at(&self, t: f64) -> f64 {
        (self.start_hour + (t - self.t0) * self.speed / 3600.0)
            .clamp(self.time.min_hour, self.time.max_hour)
    }

    /// Номер шага погоды, в который попадает `t`.
    pub fn step_index(&self, t: f64) -> i64 {
        (self.hour_at(t) / self.quantum_h).floor() as i64
    }

    fn weather_q(&mut self, q: i64) -> Arc<WeatherMap> {
        if let Some(w) = self.cache.get(&q) {
            return w.clone();
        }
        if self.cache.len() > CACHE_MAX {
            self.cache.clear();
        }
        let w = Arc::new(match &self.weather_fn {
            Some(f) => f(q as f64 * self.quantum_h),
            None => WeatherMap::new(),
        });
        self.cache.insert(q, w.clone());
        w
    }

    /// Погода шага, в который попадает `t` (для рождения термиков).
    pub fn weather_at(&mut self, t: f64) -> Arc<WeatherMap> {
        let q = self.step_index(t);
        self.weather_q(q)
    }

    /// Для плавных величин: (погода шага, погода следующего шага, доля 0..1) в момент `t`.
    pub fn bracket(&mut self, t: f64) -> (Arc<WeatherMap>, Arc<WeatherMap>, f64) {
        let qf = self.hour_at(t) / self.quantum_h;
        let q = qf.floor();
        let (w0, w1) = (self.weather_q(q as i64), self.weather_q(q as i64 + 1));
        (w0, w1, qf - q)
    }

    /// Число из погоды, плавно по времени (линейно между шагами).
    pub fn value_at(&mut self, t: f64, key: &str, default: f64) -> f64 {
        let (w0, w1, f) = self.bracket(t);
        lerp(get_or(&w0, key, default), get_or(&w1, key, default), f)
    }

    /// Направление НА солнце в момент `t`; нулевой вектор — не задано.
    pub fn sun_at(&self, t: f64) -> [f32; 3] {
        match &self.sun {
            Some(s) => sun_direction(self.hour_at(t), s, self.time.min_light_elevation_deg),
            None => [0.0; 3],
        }
    }

    /// Сила источника термиков в точке в момент `t`, зажата в 0..1; `None` — не задано
    /// (GD: -1, брать `GroundField.sun`).
    pub fn source_at(&self, x: f64, z: f64, t: f64) -> Option<f64> {
        let f = self.source_fn.as_ref()?;
        Some(f(x, z, self.hour_at(t)).clamp(0.0, 1.0))
    }

    /// Часы пошли иначе: с момента `t` час — `hour`, дальше со скоростью `new_speed`. Кеш остаётся.
    pub fn rebase(&mut self, t: f64, hour: f64, new_speed: f64) {
        self.t0 = t;
        self.start_hour = hour;
        self.speed = new_speed;
    }
}

/// Число `key` словаря погоды; нет ключа или не число — `def` (GD: `float(d.get(key, def))`).
pub(crate) fn get_or(w: &WeatherMap, key: &str, def: f64) -> f64 {
    w.get(key).and_then(Value::as_f64).unwrap_or(def)
}

/// `weather_fn` дня по прогнозу (см. [`AtmoDay::from_forecast`]).
pub fn forecast_weather_fn(
    forecast: Forecast,
    ctx: PlaceCtx,
    climate: ClimatePlace,
    cfg: WeatherModelCfg,
    overrides: WeatherMap,
) -> WeatherFn {
    let peak = get_or(
        &derive(&forecast, &ctx, f64::NAN, &climate, &cfg),
        "thermal_spacing_m",
        0.0,
    );
    Box::new(move |h| {
        let mut w = derive(&forecast, &ctx, h, &climate, &cfg);
        w.insert("thermal_spacing_m".into(), super::tables::num_value(peak));
        for (k, v) in &overrides {
            w.insert(k.clone(), v.clone());
        }
        w.remove("static_thermals");
        w
    })
}
