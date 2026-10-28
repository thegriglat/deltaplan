//! Ветровая рамка: перенос `WindModel` (`scripts/atmosphere/wind_model.gd`) без шума
//! (`gust_unit` — RW-9) и `WeatherView` — снимок выведенной погоды для слагаемых.
//!
//! Профиль по высоте — `field::wind_profile` (одна функция с решателем, не дублируется).
use crate::Configs;
use crate::field::wind_profile::{self, F_COR, WindProfileCfg};
use serde_json::{Map, Value};

/// `AirCase.Z0`: шероховатость, с которой решатель и `WindModel` считают предел профиля, м.
pub const AIR_CASE_Z0: f64 = 0.1;

/// Снимок выведенной погоды: словарь с теми же ключами, что у словаря погоды GD (ключи
/// `configs/weather/*.json` и подсловарь `_derived`). Типизированные геттеры — с запасным значением.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct WeatherView {
    map: Map<String, Value>,
}

impl WeatherView {
    pub fn new(map: Map<String, Value>) -> Self {
        WeatherView { map }
    }

    pub fn map(&self) -> &Map<String, Value> {
        &self.map
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.map.get(key)
    }

    /// Число по ключу; нет ключа или не число — `default`.
    pub fn f64_or(&self, key: &str, default: f64) -> f64 {
        self.map
            .get(key)
            .and_then(Value::as_f64)
            .filter(|v| v.is_finite())
            .unwrap_or(default)
    }

    /// Число из подсловаря `_derived`.
    pub fn derived_f64_or(&self, key: &str, default: f64) -> f64 {
        self.map
            .get("_derived")
            .and_then(|d| d.get(key))
            .and_then(Value::as_f64)
            .filter(|v| v.is_finite())
            .unwrap_or(default)
    }

    pub fn str_or<'a>(&'a self, key: &str, default: &'a str) -> &'a str {
        self.map.get(key).and_then(Value::as_str).unwrap_or(default)
    }
}

/// Параметры рамки: `atmosphere.json` → `wind`, `wind_profile_simple`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindCfg {
    /// `reference_height_m`.
    pub ref_h: f64,
    /// `roughness_height_m`: ниже профиль не убывает.
    pub z0: f64,
    /// `altitude_gain_per_km`.
    pub alt_gain: f64,
    pub alt_min: f64,
    pub alt_max: f64,
    pub profile: WindProfileCfg,
    /// `wind_profile_simple.alpha` / `max_factor`.
    pub simple_alpha: f64,
    pub simple_max: f64,
}

impl Default for WindCfg {
    fn default() -> Self {
        WindCfg {
            ref_h: 10.0,
            z0: 1.0,
            alt_gain: 0.0,
            alt_min: 1.0,
            alt_max: 1.0,
            profile: WindProfileCfg::default(),
            simple_alpha: 0.14,
            simple_max: 1.8,
        }
    }
}

impl WindCfg {
    /// Из конфигов; нет `atmosphere` или ключа — запасные значения `WindModel`.
    pub fn from_configs(c: &Configs) -> Self {
        let atm = c
            .files
            .iter()
            .find(|(n, _)| n == "atmosphere" || n == "atmosphere.json")
            .and_then(|(_, t)| serde_json::from_str::<Value>(t).ok())
            .unwrap_or(Value::Null);
        let d = WindCfg::default();
        let w = |k: &str, dv: f64| {
            atm.pointer(&format!("/wind/{k}"))
                .and_then(Value::as_f64)
                .unwrap_or(dv)
        };
        let s = |k: &str, dv: f64| {
            atm.pointer(&format!("/wind_profile_simple/{k}"))
                .and_then(Value::as_f64)
                .unwrap_or(dv)
        };
        WindCfg {
            ref_h: w("reference_height_m", d.ref_h),
            z0: w("roughness_height_m", d.z0),
            alt_gain: w("altitude_gain_per_km", d.alt_gain),
            alt_min: w("altitude_min_factor", d.alt_min),
            alt_max: w("altitude_max_factor", d.alt_max),
            profile: WindProfileCfg {
                alpha_n: w("shear_exponent_neutral", d.profile.alpha_n),
                z_sat_frac: w("z_sat_frac", d.profile.z_sat_frac),
            },
            simple_alpha: s("alpha", d.simple_alpha),
            simple_max: s("max_factor", d.simple_max),
        }
    }
}

/// Средний ветер: степенной профиль по высоте (`WindModel` без шума).
#[derive(Clone, Debug, PartialEq)]
pub struct WindModel {
    cfg: WindCfg,
    /// Рост ветра с высотой места, 1/км (`set_altitude_gain`).
    alt_gain: f64,
    /// Куда дует (горизонтальный единичный вектор, `(x, z)` мира): `(−sin d, cos d)`.
    dir: [f64; 2],
    /// Скорость на опорной высоте, м/с.
    pub speed_ref: f64,
    /// Метеонаправление «откуда», градусы.
    pub from_deg: f64,
    /// Высота над морем, на которой задан ветер прогноза; NaN — не зависит от высоты.
    pub ref_msl: f64,
    sun_elev_deg: f64,
    cover: f64,
    simple: bool,
    simple_alpha: f64,
    simple_max: f64,
    alpha: f64,
    max_f: f64,
}

impl Default for WindModel {
    fn default() -> Self {
        WindModel::new(WindCfg::default())
    }
}

impl WindModel {
    /// Модель без ветра (`speed_ref = 0`), условия устойчивости — как у `WindModel.gd` (солнце 52°,
    /// облачности нет).
    pub fn new(cfg: WindCfg) -> Self {
        let mut m = WindModel {
            alt_gain: cfg.alt_gain,
            dir: [0.0, 1.0],
            speed_ref: 0.0,
            from_deg: 0.0,
            ref_msl: f64::NAN,
            sun_elev_deg: 52.0,
            cover: 0.0,
            simple: false,
            simple_alpha: cfg.simple_alpha,
            simple_max: cfg.simple_max,
            alpha: 0.24,
            max_f: 1.0,
            cfg,
        };
        m.update_profile();
        m
    }

    pub fn cfg(&self) -> &WindCfg {
        &self.cfg
    }

    /// Направление, куда дует ветер: `(x, z)` мира.
    pub fn dir(&self) -> [f64; 2] {
        self.dir
    }

    pub fn is_simple(&self) -> bool {
        self.simple
    }

    /// Ветер «откуда» `from_deg` (0 — с севера), скорость на опорной высоте, м/с.
    pub fn set_wind(&mut self, speed_ms: f64, from_deg: f64) {
        self.speed_ref = speed_ms.max(0.0);
        self.from_deg = from_deg;
        let d = from_deg.to_radians();
        self.dir = [-d.sin(), d.cos()];
        self.update_profile();
    }

    /// Ветер и опорная высота из погоды: `wind_speed_kmh`, `wind_from_deg`.
    pub fn set_from_weather(&mut self, w: &WeatherView) {
        self.set_wind(
            w.f64_or("wind_speed_kmh", 0.0) / 3.6,
            w.f64_or("wind_from_deg", 270.0),
        );
    }

    /// Условия устойчивости: высота солнца (°), облачность 0..1 (класс Тёрнера).
    pub fn set_conditions(&mut self, sun_elev_deg: f64, cover: f64) {
        self.sun_elev_deg = sun_elev_deg;
        self.cover = cover.clamp(0.0, 1.0);
        self.update_profile();
    }

    /// Профиль 0.8.0 для упрощённого режима; `cfg` — `(alpha, max_factor)`, `None` — прежние.
    pub fn set_simple_profile(&mut self, on: bool, cfg: Option<(f64, f64)>) {
        if let Some((a, m)) = cfg {
            self.simple_alpha = a;
            self.simple_max = m;
        }
        self.simple = on;
        self.update_profile();
    }

    /// Рост ветра с высотой места, 1/км; NaN — оставить прежний (из конфига).
    pub fn set_altitude_gain(&mut self, gain_per_km: f64) {
        if !gain_per_km.is_nan() {
            self.alt_gain = gain_per_km;
        }
    }

    fn update_profile(&mut self) {
        if self.simple {
            self.alpha = self.simple_alpha;
            self.max_f = self.simple_max;
            return;
        }
        let c = wind_profile::apply_to_case(
            &self.cfg.profile,
            self.speed_ref,
            AIR_CASE_Z0,
            F_COR,
            self.sun_elev_deg,
            self.cover,
        );
        self.alpha = c.alpha;
        self.max_f = c.max_profile;
    }

    /// `(α, предел)` профиля.
    pub fn profile_params(&self) -> (f64, f64) {
        (self.alpha, self.max_f)
    }

    /// Множитель профиля на высоте `agl` над землёй.
    pub fn profile(&self, agl: f64) -> f64 {
        ((agl.max(self.cfg.z0) / self.cfg.ref_h).powf(self.alpha)).min(self.max_f)
    }

    pub fn speed_at(&self, agl: f64) -> f64 {
        self.speed_ref * self.profile(agl)
    }

    /// Множитель ветра от высоты над стартом; 1 — если опорная высота не задана.
    pub fn altitude_factor(&self, msl: f64) -> f64 {
        if self.ref_msl.is_nan() {
            return 1.0;
        }
        // clampf GDScript: без паники при alt_min > alt_max
        let f = 1.0 + self.alt_gain * (msl - self.ref_msl) / 1000.0;
        if f < self.cfg.alt_min {
            self.cfg.alt_min
        } else if f > self.cfg.alt_max {
            self.cfg.alt_max
        } else {
            f
        }
    }

    /// Скорость на высоте `agl` над рельефом в точке с высотой `msl` над морем, м/с.
    pub fn speed_at_pos(&self, agl: f64, msl: f64) -> f64 {
        self.speed_ref * self.profile(agl) * self.altitude_factor(msl)
    }

    /// Горизонтальный ветер `(x, z)` на высоте `agl`.
    pub fn vec2_at(&self, agl: f64) -> [f64; 2] {
        let s = self.speed_at(agl);
        [self.dir[0] * s, self.dir[1] * s]
    }
}
