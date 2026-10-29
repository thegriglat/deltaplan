//! Логика `DpWeather` (W12 v2) без типов Godot: разбор JSON, коды W1, вызовы `dp_air::weather`.
//! Класс gdext в `lib.rs` только переводит типы Godot. Состояние — один `Arc<Weather>`;
//! до `configure` числа — NaN, словари (JSON-строки) — `{}`, `sky_params` — пусто.
use dp_air::weather::{ClimateGrids, PlaceCtx, Weather, hour_at, valley_of};
use dp_air::{Configs, Forecast};
use serde_json::{Value, json};
use std::sync::Arc;

use crate::bridge::BAD_INPUT;

/// Контекст места из json: `month`, `day`, `lat`, `lon`, `utc_offset_h`, `valley_msl_m`,
/// `mean_msl_m`, `start_msl_m`. Нет ключа или `null` — `NaN` (`month`/`day` — 7/15).
pub fn ctx_from_json(text: &str) -> PlaceCtx {
    let v: Value = serde_json::from_str(text).unwrap_or(Value::Null);
    let f = |k: &str| v.get(k).and_then(Value::as_f64).unwrap_or(f64::NAN);
    let i = |k: &str, def: i64| {
        let x = f(k);
        if x.is_nan() { def } else { x as i64 }
    };
    PlaceCtx {
        month: i("month", 7),
        day: i("day", 15),
        lat: f("lat"),
        lon: f("lon"),
        utc_offset_h: f("utc_offset_h"),
        valley_msl_m: f("valley_msl_m"),
        mean_msl_m: f("mean_msl_m"),
        start_msl_m: f("start_msl_m"),
    }
}

/// Число в json: не конечное — `null`.
pub fn num(v: f64) -> Value {
    serde_json::Number::from_f64(v).map_or(Value::Null, Into::into)
}

#[derive(Default)]
pub struct WeatherBridge {
    weather: Option<Arc<Weather>>,
}

impl WeatherBridge {
    /// `pairs` — имя секции, текст, …; сетки — имя (`hh1`…`hh6`) и распакованные байты (W12 v2).
    /// Коды W1; при ошибке прежняя погода остаётся.
    pub fn configure(&mut self, pairs: &[String], names: &[String], bytes: &[&[u8]]) -> i64 {
        if !pairs.len().is_multiple_of(2) || names.len() != bytes.len() {
            return BAD_INPUT;
        }
        let cfg = Configs::new(
            pairs
                .chunks_exact(2)
                .map(|c| (c[0].clone(), c[1].clone()))
                .collect(),
        );
        let items: Vec<(&str, &[u8])> = names
            .iter()
            .map(String::as_str)
            .zip(bytes.iter().copied())
            .collect();
        match Weather::new(&cfg, ClimateGrids::from_bytes(&items)) {
            Ok(w) => {
                self.weather = Some(Arc::new(w));
                0
            }
            Err(e) => i64::from(e.code.as_int()),
        }
    }

    /// Общая погода (для `DpAir.attach_weather`).
    pub fn arc(&self) -> Option<Arc<Weather>> {
        self.weather.clone()
    }

    pub fn typical_max_c(&self, month: i64, day: i64, lat: f64, lon: f64, valley: f64) -> f64 {
        self.weather
            .as_ref()
            .map_or(f64::NAN, |w| w.typical_max_c(month, day, lat, lon, valley))
    }

    pub fn diurnal_state(&self, t_max: f64, hour: f64, ctx: &str) -> String {
        let Some(w) = &self.weather else {
            return "{}".into();
        };
        let s = w.diurnal_state(t_max, hour, &ctx_from_json(ctx));
        json!({
            "temperature_c": num(s.temperature_c), "cap_agl_m": num(s.cap_agl_m),
            "brk": num(s.brk), "heat": num(s.heat), "soft": num(s.soft),
            "mech_k": num(s.mech_k), "sunrise_h": num(s.sunrise_h),
            "sunset_h": num(s.sunset_h), "peak_h": num(s.peak_h),
        })
        .to_string()
    }

    pub fn sunrise_h(&self, t_max: f64, ctx: &str) -> f64 {
        self.weather
            .as_ref()
            .map_or(f64::NAN, |w| w.sunrise_h(t_max, &ctx_from_json(ctx)))
    }

    pub fn sunset_h(&self, t_max: f64, ctx: &str) -> f64 {
        self.weather
            .as_ref()
            .map_or(f64::NAN, |w| w.sunset_h(t_max, &ctx_from_json(ctx)))
    }

    /// `[cover, sky_heat]`; до `configure` — пусто.
    pub fn sky_params(&self, sky: &str) -> Vec<f32> {
        self.weather.as_ref().map_or_else(Vec::new, |w| {
            let (c, h) = w.sky_params(sky);
            vec![c as f32, h as f32]
        })
    }

    /// Словарь погоды с `_derived`; прогноз не разобрался — `{}`.
    pub fn derive(&self, forecast: &str, ctx: &str, hour: f64) -> String {
        let (Some(w), Ok(f)) = (&self.weather, serde_json::from_str::<Forecast>(forecast)) else {
            return "{}".into();
        };
        let m = w.derive(&f, &ctx_from_json(ctx), hour);
        Value::Object(m).to_string()
    }

    pub fn air_temp_c(&self, hour: f64, t_max: f64, z: f64, ctx: &str) -> f64 {
        self.weather.as_ref().map_or(f64::NAN, |w| {
            w.air_temp_c(hour, t_max, z, &ctx_from_json(ctx))
        })
    }

    pub fn water_temp_c(&self, month: i64, day: i64, z: f64, ctx: &str) -> f64 {
        self.weather.as_ref().map_or(f64::NAN, |w| {
            w.water_temp_c(month, day, z, &ctx_from_json(ctx))
        })
    }

    pub fn temp_at_altitude(&self, weather: &str, alt_msl: f64, month: i64, day: i64) -> f64 {
        let (Some(w), Ok(Value::Object(m))) = (&self.weather, serde_json::from_str(weather)) else {
            return f64::NAN;
        };
        w.temp_at_altitude(&m, alt_msl, month, day)
    }

    pub fn climate_cell(&self, lat: f64, lon: f64, month: i64, day: i64) -> String {
        let Some(w) = &self.weather else {
            return "{}".into();
        };
        let c = w.climate_at(lat, lon, month, day);
        json!({
            "td_c": num(c.td_c), "td_sd_k": num(c.td_sd_k), "z_cell_m": num(c.z_cell_m),
            "t700_c": num(c.t700_c), "z700_m": num(c.z700_m), "tx_c": num(c.tx_c),
            "dtr_k": num(c.dtr_k), "wr": num(c.wr), "trop_m": num(c.trop_m), "hcc": num(c.hcc),
            "src": {"hh1": c.src.hh1, "hh2": c.src.hh2, "hh5": c.src.hh5, "hh6": c.src.hh6},
        })
        .to_string()
    }

    pub fn reference_context(&self) -> String {
        let Some(w) = &self.weather else {
            return "{}".into();
        };
        let c = w.reference_context();
        json!({
            "month": c.month, "day": c.day, "lat": num(c.lat), "lon": num(c.lon),
            "utc_offset_h": num(c.utc_offset_h), "valley_msl_m": num(c.valley_msl_m),
            "mean_msl_m": num(c.mean_msl_m),
        })
        .to_string()
    }

    pub fn quantum_h(&self) -> f64 {
        self.weather.as_ref().map_or(f64::NAN, |w| w.quantum_h())
    }

    pub fn hour_at(&self, start_hour: f64, speed: f64, t: f64, world_time: f64) -> f64 {
        // `world_time` — зарезервированный аргумент W12 §2 (границы времени берутся из конфига).
        let _ = world_time;
        self.weather
            .as_ref()
            .map_or(f64::NAN, |w| hour_at(start_hour, speed, t, &w.world_time()))
    }

    pub fn valley_of(&self, samples: &[f32], percentile: f64) -> f64 {
        valley_of(samples, percentile)
    }
}
