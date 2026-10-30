//! Коэффициенты суммы ветра из конфига секция `atmosphere` и словаря погоды (`Atmosphere._cache_coefficients`
//! и стартовые значения `_configure_legacy`, RW-12c). Чистые числа без движка.
//!
//! Не здесь: `_advect` (скорость ветра на высоте сноса — зависит от профиля ветра, RW-9).
use serde_json::{Map, Value};

use super::day::{WeatherMap, get_or};
use super::derive::sun_block_cover;
use super::tables::{num, num_value};
use crate::field::weather_core::WeatherModelCfg;

/// Профиль Lenschow σw ∝ √(1,8 ξ^(2/3) (1 − 0,8ξ)²) (`Atmosphere._lenschow`).
fn lenschow(xi: f64) -> f64 {
    let a = 1.0 - 0.8 * xi;
    (1.8 * xi.powf(2.0 / 3.0) * a * a).sqrt()
}

/// Коэффициенты суммы. Поля `bg_sink`, `conv_amp`, `mech_k`, `edge_factor`, `insolation`,
/// `cloudbase_agl` плавно меняются со сменой погоды (ход дня, мягкая смена); остальные — конфиг.
#[derive(Clone, Debug, PartialEq)]
pub struct Coefficients {
    pub bg_sink: f64,
    pub ground_fade: f64,
    pub ridge_eff: f64,
    pub ridge_decay: f64,
    pub ridge_shift_k: f64,
    pub ridge_shift_max: f64,
    pub ridge_max: f64,
    pub lee_depth: f64,
    pub lee_relief: f64,
    pub lee_sink: f64,
    pub lee_turb: f64,
    pub lee_wind_red: f64,
    pub lee_shear: f64,
    pub lee_danger_min: f64,
    pub lee_danger_full: f64,
    pub lee_danger_sink: f64,
    pub lee_danger_turb: f64,
    pub lee_burst: f64,
    pub lee_burst_k: f64,
    pub lee_burst_thr: f64,
    pub lee_burst_width: f64,
    pub lee_reverse: f64,
    pub lee_rotor_h: f64,
    pub lee_rotor_max: f64,
    pub lee_heat_full: f64,
    pub lee_heat_wstar_k: f64,
    pub mech_k_base: f64,
    pub mech_k: f64,
    pub mech_boost: f64,
    pub mech_h: f64,
    pub vert_ratio: f64,
    pub turb_max: f64,
    pub conv_amp: f64,
    pub conv_norm: f64,
    pub wave_ref_agl: f64,
    pub in_cloud_turb: f64,
    pub in_cloud_eject: f64,
    pub in_cloud_scale_k: f64,
    pub edge_factor_base: f64,
    pub edge_width: f64,
    /// Болтанка на краю термика: `edge_factor_base · thermal_edge_k` (плавно).
    pub edge_factor: f64,
    /// Прогрев 0..1: `1 − sun_block_cover · cirrus.sun_block` (плавно).
    pub insolation: f64,
    /// Кромка облаков над землёй, м (плавно).
    pub cloudbase_agl: f64,
    /// `cirrus.sun_block` (для `insolation` по ходу дня).
    pub sun_block: f64,
}

impl Coefficients {
    /// Из секция `atmosphere` и словаря погоды. Ключ блока, которого нет в конфиге, — 0 (в GD — ошибка;
    /// отгруженный конфиг ключи содержит); необязательные ключи `lee` — запасные значения GD.
    pub fn new(atm: &Value, weather: &Map<String, Value>) -> Self {
        let g = |sec: &str, k: &str, def: f64| num(atm, &[sec, k], def);
        let sun_block = g("cirrus", "sun_block", 0.0);
        let lee_sink = g("lee", "sink_per_wind", 0.0);
        let lee_turb = g("lee", "turbulence_per_wind", 0.0);
        let mech_k_base = g("turbulence", "mech_per_wind", 0.0);
        let edge_factor_base = g("turbulence", "edge_factor", 0.0);
        let mut peak = 0.0f64;
        for i in 0..=100 {
            peak = peak.max(lenschow(i as f64 / 100.0));
        }
        Coefficients {
            bg_sink: get_or(weather, "background_sink_ms", 0.0),
            ground_fade: num(atm, &["ground_fade_m"], 0.0),
            ridge_eff: g("ridge", "efficiency", 0.0),
            ridge_decay: g("ridge", "decay_height_m", 0.0),
            ridge_shift_k: g("ridge", "forward_shift_factor", 0.0),
            ridge_shift_max: g("ridge", "forward_shift_max_m", 0.0),
            ridge_max: g("ridge", "max_lift_ms", 0.0),
            lee_depth: g("lee", "depth_scale_m", 0.0),
            lee_relief: g("lee", "relief_scale_m", 0.0),
            lee_sink,
            lee_turb,
            lee_wind_red: g("lee", "wind_reduction", 0.0),
            lee_shear: g("lee", "shear_layer_m", 0.0),
            lee_danger_min: g("lee", "danger_min_wind_ms", 2.0),
            lee_danger_full: g("lee", "danger_full_wind_ms", 5.0),
            lee_danger_sink: g("lee", "danger_sink_per_wind", lee_sink),
            lee_danger_turb: g("lee", "danger_turbulence_per_wind", lee_turb),
            lee_burst: g("lee", "burst_per_wind", 0.0),
            lee_burst_k: g("turbulence", "scale_m", 0.0) / g("lee", "burst_scale_m", 120.0),
            lee_burst_thr: g("lee", "burst_threshold", 0.8),
            lee_burst_width: g("lee", "burst_width", 1.0),
            lee_reverse: g("lee", "rotor_reverse", 0.0),
            lee_rotor_h: g("lee", "rotor_height_fraction", 0.4),
            lee_rotor_max: g("lee", "rotor_max_amplitude_ms", 0.0),
            lee_heat_full: g("lee", "heat_kill_wm2", 0.0),
            lee_heat_wstar_k: g("lee", "heat_sigma_per_wstar", 0.6),
            mech_k_base,
            mech_k: mech_k_base * get_or(weather, "mech_turbulence_k", 1.0),
            mech_boost: g("turbulence", "mech_ground_boost", 0.0),
            mech_h: g("turbulence", "mech_ground_height_m", 0.0),
            vert_ratio: g("turbulence", "vertical_ratio", 0.0),
            turb_max: g("turbulence", "max_amplitude_ms", 0.0),
            conv_amp: get_or(weather, "convective_turbulence_ms", 0.0),
            conv_norm: 1.0 / peak.max(1.0e-4),
            wave_ref_agl: g("wave", "wind_reference_agl_m", 0.0),
            in_cloud_turb: g("turbulence", "in_cloud_ms", 0.0),
            in_cloud_eject: g("turbulence", "in_cloud_eject_ms", 0.0),
            in_cloud_scale_k: g("turbulence", "scale_m", 0.0)
                / g("turbulence", "in_cloud_scale_m", 1.0),
            edge_factor_base,
            edge_width: g("turbulence", "edge_width", 0.0),
            edge_factor: edge_factor_base * get_or(weather, "thermal_edge_k", 1.0),
            insolation: 1.0 - sun_block_cover(weather) * sun_block,
            cloudbase_agl: get_or(weather, "cloudbase_agl_m", 0.0),
            sun_block,
        }
    }

    /// Все коэффициенты словарём с теми же именами, что в дампе GD (без `sun_block`).
    pub fn to_map(&self) -> Map<String, Value> {
        let mut m = Map::new();
        for (k, v) in self.named() {
            m.insert(k.into(), num_value(v));
        }
        m
    }

    fn named(&self) -> [(&'static str, f64); 43] {
        [
            ("bg_sink", self.bg_sink),
            ("ground_fade", self.ground_fade),
            ("ridge_eff", self.ridge_eff),
            ("ridge_decay", self.ridge_decay),
            ("ridge_shift_k", self.ridge_shift_k),
            ("ridge_shift_max", self.ridge_shift_max),
            ("ridge_max", self.ridge_max),
            ("lee_depth", self.lee_depth),
            ("lee_relief", self.lee_relief),
            ("lee_sink", self.lee_sink),
            ("lee_turb", self.lee_turb),
            ("lee_wind_red", self.lee_wind_red),
            ("lee_shear", self.lee_shear),
            ("lee_danger_min", self.lee_danger_min),
            ("lee_danger_full", self.lee_danger_full),
            ("lee_danger_sink", self.lee_danger_sink),
            ("lee_danger_turb", self.lee_danger_turb),
            ("lee_burst", self.lee_burst),
            ("lee_burst_k", self.lee_burst_k),
            ("lee_burst_thr", self.lee_burst_thr),
            ("lee_burst_width", self.lee_burst_width),
            ("lee_reverse", self.lee_reverse),
            ("lee_rotor_h", self.lee_rotor_h),
            ("lee_rotor_max", self.lee_rotor_max),
            ("lee_heat_full", self.lee_heat_full),
            ("lee_heat_wstar_k", self.lee_heat_wstar_k),
            ("mech_k_base", self.mech_k_base),
            ("mech_k", self.mech_k),
            ("mech_boost", self.mech_boost),
            ("mech_h", self.mech_h),
            ("vert_ratio", self.vert_ratio),
            ("turb_max", self.turb_max),
            ("conv_amp", self.conv_amp),
            ("conv_norm", self.conv_norm),
            ("wave_ref_agl", self.wave_ref_agl),
            ("in_cloud_turb", self.in_cloud_turb),
            ("in_cloud_eject", self.in_cloud_eject),
            ("in_cloud_scale_k", self.in_cloud_scale_k),
            ("edge_factor_base", self.edge_factor_base),
            ("edge_width", self.edge_width),
            ("edge_factor", self.edge_factor),
            ("insolation", self.insolation),
            ("cloudbase_agl", self.cloudbase_agl),
        ]
    }
}

/// Условия устойчивости профиля ветра из погоды (`Atmosphere._wind_conditions`): (высота солнца часа, °;
/// облачность 0..1). Час — `_derived.sun_elev_deg` (пресет без часа — `clouds.sun_elevation_deg` из
/// секция `atmosphere`), облачность — `sky_params(_derived.sky).cover` (пресет — ясно, 0).
pub fn wind_conditions(atm: &Value, weather: &WeatherMap, wm: &WeatherModelCfg) -> (f64, f64) {
    let dv = weather.get("_derived").and_then(Value::as_object);
    let sun = dv
        .and_then(|d| d.get("sun_elev_deg"))
        .and_then(Value::as_f64)
        .unwrap_or_else(|| num(atm, &["clouds", "sun_elevation_deg"], 0.0));
    let cover = dv
        .and_then(|d| d.get("sky"))
        .and_then(Value::as_str)
        .map_or(0.0, |s| wm.sky_params(s).0);
    (sun, cover)
}
