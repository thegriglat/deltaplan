//! Поток тепла с поверхности H, Вт/м² (> 0 вверх): перенос `SurfaceHeat` (SH1/SH2) и
//! `SurfaceHeating` (инерция прогрева классов). Суша: K↓ (Stull) → Rn = (1 − α)K↓ − L* →
//! G = g_frac·Rn → H = (Rn − G)·β/(1 + β). Вода: H = ρ·c_p·C_H·max(U, U_min)·(T_в − T_в-ха).
//! Только чистые функции: без состояния и случайности.
use super::sun::{day_of_year, lerp, solar_position, sun_direction};
use crate::error::Error;
use serde_json::Value;

pub const CLASS_COUNT: usize = 9;
pub const CLASS_NAMES: [&str; CLASS_COUNT] = [
    "none", "forest", "grass", "crop", "shrub", "bare", "water", "built", "snow",
];
pub const NONE: usize = 0;
pub const WATER: usize = 6;
pub const BUILT: usize = 7;
pub const SNOW: usize = 8;

/// Число по пути в json; нет или не число — `def`.
pub(crate) fn num(v: &Value, path: &[&str], def: f64) -> f64 {
    let mut cur = v;
    for k in path {
        match cur.get(k) {
            Some(n) => cur = n,
            None => return def,
        }
    }
    cur.as_f64().unwrap_or(def)
}

/// Параметры класса поверхности (`classes.<имя>`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ClassCfg {
    pub albedo: f64,
    pub bowen: f64,
    pub bowen_min: f64,
    pub bowen_max: f64,
    pub g_frac: f64,
    pub z0_m: f64,
    pub night_floor_wm2: f64,
    pub night_tau_h: f64,
}

/// Параметры воды (`water`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WaterCfg {
    pub c_h: f64,
    pub rho_cp: f64,
    pub rho_scale_height_m: f64,
    pub u_min_ms: f64,
    pub lag_days: f64,
    pub ice_c: f64,
    pub lapse_k_per_km: f64,
}

/// `configs/surface_heat.json`: неизвестные ключи не ошибка, числа классов обязательны.
#[derive(Clone, Debug, PartialEq)]
pub struct SurfaceHeatCfg {
    pub classes: [ClassCfg; CLASS_COUNT],
    pub s0_wm2: f64,
    pub tk_a: f64,
    pub tk_b: f64,
    pub cloud_sw_k: f64,
    pub diffuse_frac: f64,
    pub l_star_wm2: f64,
    pub l_cloud_k: f64,
    pub m_dry: f64,
    pub m_norm: f64,
    pub m_wet: f64,
    /// `moisture.m_norm` для клеток без поля влажности (в `AirPlace` запасное значение 0,5).
    pub m_norm_cells: f64,
    pub water: WaterCfg,
}

impl SurfaceHeatCfg {
    pub fn from_value(v: &Value) -> Result<Self, Error> {
        let mut classes = [ClassCfg {
            albedo: 0.0,
            bowen: 0.0,
            bowen_min: 0.0,
            bowen_max: 0.0,
            g_frac: 0.0,
            z0_m: 0.0,
            night_floor_wm2: 0.0,
            night_tau_h: 1.5,
        }; CLASS_COUNT];
        for (k, name) in CLASS_NAMES.iter().enumerate() {
            let c = v
                .get("classes")
                .and_then(|c| c.get(*name))
                .ok_or_else(|| Error::bad_input(format!("surface_heat: no classes.{name}")))?;
            let req = |key: &str| {
                c.get(key).and_then(Value::as_f64).ok_or_else(|| {
                    Error::bad_input(format!("surface_heat: classes.{name}.{key} missing"))
                })
            };
            classes[k] = ClassCfg {
                albedo: req("albedo")?,
                bowen: req("bowen")?,
                bowen_min: req("bowen_min")?,
                bowen_max: req("bowen_max")?,
                g_frac: req("g_frac")?,
                z0_m: req("z0_m")?,
                night_floor_wm2: num(c, &["night_floor_wm2"], 0.0),
                night_tau_h: num(c, &["night_tau_h"], 1.5),
            };
        }
        Ok(SurfaceHeatCfg {
            classes,
            s0_wm2: num(v, &["radiation", "s0_wm2"], 1361.0),
            tk_a: num(v, &["radiation", "tk_a"], 0.6),
            tk_b: num(v, &["radiation", "tk_b"], 0.2),
            cloud_sw_k: num(v, &["radiation", "cloud_sw_k"], 0.7),
            diffuse_frac: num(v, &["radiation", "diffuse_frac"], 0.165),
            l_star_wm2: num(v, &["radiation", "l_star_wm2"], 98.5),
            l_cloud_k: num(v, &["radiation", "l_cloud_k"], 0.3),
            m_dry: num(v, &["moisture", "m_dry"], 0.25),
            m_norm: num(v, &["moisture", "m_norm"], 0.47),
            m_wet: num(v, &["moisture", "m_wet"], 0.70),
            m_norm_cells: num(v, &["moisture", "m_norm"], 0.5),
            water: WaterCfg {
                c_h: num(v, &["water", "c_h"], 1.4e-3),
                rho_cp: num(v, &["water", "rho_cp"], 1206.0),
                rho_scale_height_m: num(v, &["water", "rho_scale_height_m"], 8400.0),
                u_min_ms: num(v, &["water", "u_min_ms"], 1.0),
                lag_days: num(v, &["water", "lag_days"], 30.0),
                ice_c: num(v, &["water", "ice_c"], 0.0),
                lapse_k_per_km: num(v, &["water", "lapse_k_per_km"], 6.5),
            },
        })
    }

    fn class(&self, cls: usize) -> &ClassCfg {
        &self.classes[cls.min(CLASS_COUNT - 1)]
    }
}

/// K↓ на поверхность, Вт/м² (Stull 1988, 2.34–2.40; разложение Эрбса). `cos_inc` — скалярное
/// произведение нормали на направление НА солнце, `sin_el` — синус высоты; облачность один раз
/// через `cover`. Нормаль без нормировки даёт поток на горизонтальную площадь.
pub fn shortwave(cos_inc: f64, sin_el: f64, cover: f64, cfg: &SurfaceHeatCfg) -> f64 {
    if sin_el <= 0.0 {
        return 0.0;
    }
    let t_r = (cfg.tk_a + cfg.tk_b * sin_el) * (1.0 - cfg.cloud_sw_k * cover.clamp(0.0, 1.0));
    let k_hor = cfg.s0_wm2 * t_r * sin_el;
    let f = diffuse_fraction(t_r, cfg.diffuse_frac);
    (1.0 - f) * k_hor * cos_inc.max(0.0) / sin_el + f * k_hor
}

/// Доля рассеянной по Эрбсу (ERB82) от индекса ясности k_T; не меньше `f_min`.
pub fn diffuse_fraction(k_t: f64, f_min: f64) -> f64 {
    let f = if k_t <= 0.22 {
        1.0 - 0.09 * k_t
    } else if k_t <= 0.80 {
        0.9511 - 0.1604 * k_t + 4.388 * k_t * k_t - 16.638 * k_t * k_t * k_t
            + 12.336 * k_t * k_t * k_t * k_t
    } else {
        0.165
    };
    f.max(f_min)
}

/// Длинноволновое выхолаживание L*, Вт/м² (> 0).
pub fn long_wave(cover: f64, cfg: &SurfaceHeatCfg) -> f64 {
    cfg.l_star_wm2 * (1.0 - cfg.l_cloud_k * cover)
}

/// β по влажности рельефа m ∈ [0, 1]: линейно по ln β между узлами сухо / норма / влажно.
pub fn bowen(cls: usize, m: f64, cfg: &SurfaceHeatCfg) -> f64 {
    let k = cfg.class(cls);
    let (b, lo, hi) = (k.bowen, k.bowen_min, k.bowen_max);
    if m <= cfg.m_dry {
        return hi;
    }
    if m >= cfg.m_wet {
        return lo;
    }
    if m <= cfg.m_norm {
        return lerp(
            hi.ln(),
            b.ln(),
            (m - cfg.m_dry) / (cfg.m_norm - cfg.m_dry).max(1e-9),
        )
        .exp();
    }
    lerp(
        b.ln(),
        lo.ln(),
        (m - cfg.m_norm) / (cfg.m_wet - cfg.m_norm).max(1e-9),
    )
    .exp()
}

/// H суши, Вт/м²; класс вода сюда не попадает (идёт через `water_flux`).
pub fn land_flux(cls: usize, k_down: f64, cover: f64, m: f64, cfg: &SurfaceHeatCfg) -> f64 {
    let k = cfg.class(cls);
    let rn = (1.0 - k.albedo) * k_down - long_wave(cover, cfg);
    let avail = rn - k.g_frac * rn;
    let b = bowen(cls, m, cfg);
    avail * b / (1.0 + b)
}

/// Плотность воздуха относительно уровня моря на высоте `z_m` (барометрически).
pub fn air_density_factor(z_m: f64, cfg: &SurfaceHeatCfg) -> f64 {
    (-z_m.max(0.0) / cfg.water.rho_scale_height_m).exp()
}

/// H воды, Вт/м²: ρ(z)·c_p·C_H·max(U, U_min)·(T_в − T_в-ха).
pub fn water_flux(t_water_c: f64, t_air_c: f64, u_ms: f64, cfg: &SurfaceHeatCfg, z_m: f64) -> f64 {
    let w = &cfg.water;
    w.rho_cp * air_density_factor(z_m, cfg) * w.c_h * u_ms.max(w.u_min_ms) * (t_water_c - t_air_c)
}

/// Застройка после заката: `sin_s` — синус высоты солнца застройки на закате, `dt_h` — часов после.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Night {
    pub sin_s: f64,
    pub dt_h: f64,
}

/// H застройки после заката: H = H_пол + (H_зак − H_пол)⁺·exp(−dt/τ).
pub fn built_night_flux(night: &Night, cover: f64, m: f64, cfg: &SurfaceHeatCfg) -> f64 {
    let k = cfg.class(BUILT);
    let floor_h = k.night_floor_wm2;
    let h_s = land_flux(
        BUILT,
        shortwave(night.sin_s, night.sin_s, cover, cfg),
        cover,
        m,
        cfg,
    );
    let tau = k.night_tau_h.max(0.01);
    floor_h + (h_s - floor_h).max(0.0) * (-night.dt_h / tau).exp()
}

/// Небо клетки: облачность, `sky_heat` (в расчёте не участвует) и ночь застройки.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sky {
    pub cover: f64,
    pub sky_heat: f64,
    pub night: Option<Night>,
}

/// Вода клетки: температуры воды и воздуха, ветер, высота над морем.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WaterIn {
    pub t_water_c: f64,
    pub t_air_c: f64,
    pub u_ms: f64,
    pub z_m: f64,
}

/// H клетки: Σ f_c·H_c, веса `fracs` нормируются (сумма 0 — весь вес NONE). `class_sun[c]` —
/// единичный вектор НА солнце класса (нулевой — под горизонтом, K↓ = 0). Вода без `water` — 0;
/// T воды ≤ `ice_c` — как SNOW.
pub fn mix_flux(
    fracs: &[f32],
    normal: [f64; 3],
    class_sun: &[[f64; 3]],
    m: f64,
    sky: &Sky,
    water: Option<&WaterIn>,
    cfg: &SurfaceHeatCfg,
) -> f64 {
    let total: f64 = fracs.iter().map(|&f| (f as f64).max(0.0)).sum();
    let mut h = 0.0;
    for (c, &fr) in fracs.iter().enumerate().take(CLASS_COUNT) {
        let mut f = if total > 0.0 {
            (fr as f64).max(0.0)
        } else if c == NONE {
            1.0
        } else {
            0.0
        };
        if f <= 0.0 {
            continue;
        }
        if total > 0.0 {
            f /= total;
        }
        let mut cls = c;
        if c == WATER {
            let Some(w) = water else { continue };
            if w.t_water_c <= cfg.water.ice_c {
                cls = SNOW;
            } else {
                h += f * water_flux(w.t_water_c, w.t_air_c, w.u_ms, cfg, w.z_m);
                continue;
            }
        }
        if cls == BUILT
            && let Some(n) = &sky.night
        {
            h += f * built_night_flux(n, sky.cover, m, cfg);
            continue;
        }
        let sun = class_sun.get(cls).copied().unwrap_or([0.0; 3]);
        let k = if sun != [0.0; 3] {
            let cos_inc = normal[0] * sun[0] + normal[1] * sun[1] + normal[2] * sun[2];
            shortwave(cos_inc, sun[1], sky.cover, cfg)
        } else {
            0.0
        };
        h += f * land_flux(cls, k, sky.cover, m, cfg);
    }
    h
}

/// Инерция прогрева поверхности: для каждого класса — направление на солнце с запаздыванием
/// класса. Без состояния: направление — чистая функция часа.
#[derive(Clone, Debug, PartialEq)]
pub struct SurfaceHeating {
    pub enabled: bool,
    pub lat_deg: f64,
    pub lon_deg: f64,
    pub utc_offset_h: f64,
    pub doy: i64,
    pub lags_h: [f64; CLASS_COUNT],
    /// Закат по часам места (ψ = 0), ч; NaN — полярный день или ночь.
    pub sunset_h: f64,
}

impl SurfaceHeating {
    /// `heating` — секция `heating` из `weather_model.json` (`enabled`, `lag_h.<класс>`).
    pub fn new(
        lat: f64,
        lon: f64,
        month: i64,
        day: i64,
        utc: f64,
        heating: &Value,
    ) -> SurfaceHeating {
        let mut lags = [0.0; CLASS_COUNT];
        for (k, name) in CLASS_NAMES.iter().enumerate() {
            lags[k] = num(heating, &["lag_h", name], 0.0);
        }
        let mut s = SurfaceHeating {
            enabled: heating
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            lat_deg: lat,
            lon_deg: lon,
            utc_offset_h: utc,
            doy: day_of_year(month, day),
            lags_h: lags,
            sunset_h: f64::NAN,
        };
        s.sunset_h = s.sunset();
        s
    }

    fn elevation(&self, hour: f64) -> f64 {
        solar_position(
            self.lat_deg,
            self.lon_deg,
            self.doy,
            hour,
            self.utc_offset_h,
        )
        .1
    }

    /// Направление на солнце в час `hour`; под горизонтом — нулевой вектор.
    pub fn sun_at(&self, hour: f64) -> [f64; 3] {
        let (az, el) = solar_position(
            self.lat_deg,
            self.lon_deg,
            self.doy,
            hour,
            self.utc_offset_h,
        );
        if el <= 0.0 {
            return [0.0; 3];
        }
        sun_direction(az, el)
    }

    /// Направления по классам на час `hour`; солнце под горизонтом — нулевые векторы.
    /// Выключено — `None` (всем классам текущее солнце).
    pub fn directions(&self, hour: f64) -> Option<[[f64; 3]; CLASS_COUNT]> {
        if !self.enabled {
            return None;
        }
        let mut out = [[0.0; 3]; CLASS_COUNT];
        if self.sun_at(hour) == [0.0; 3] {
            return Some(out);
        }
        for (k, o) in out.iter_mut().enumerate() {
            *o = self.sun_at(hour - self.lags_h[k]);
        }
        Some(out)
    }

    /// Застройка после заката; `None` — солнце над горизонтом или закат не найден.
    pub fn built_night(&self, hour: f64) -> Option<Night> {
        if self.sunset_h.is_nan() || self.sun_at(hour) != [0.0; 3] || hour < self.sunset_h {
            return None;
        }
        let el = self.elevation(self.sunset_h - self.lags_h[BUILT]);
        Some(Night {
            sin_s: el.to_radians().sin().max(0.0),
            dt_h: hour - self.sunset_h,
        })
    }

    /// Закат: от самого высокого солнца вперёд, где ψ впервые ≤ 0 (бисекция); NaN — нет.
    fn sunset(&self) -> f64 {
        let hi0 = 24.0;
        if self.elevation(hi0) > 0.0 {
            return f64::NAN;
        }
        let mut best = 12.0;
        let mut best_el = f64::NEG_INFINITY;
        for i in 0..25 {
            let h = 6.0 + i as f64 * 0.5;
            let el = self.elevation(h);
            if el > best_el {
                best_el = el;
                best = h;
            }
        }
        if best_el <= 0.0 {
            return f64::NAN;
        }
        let (mut lo, mut hi) = (best, hi0);
        for _ in 0..40 {
            let mid = 0.5 * (lo + hi);
            if self.elevation(mid) > 0.0 {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        0.5 * (lo + hi)
    }
}
