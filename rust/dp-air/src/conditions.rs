//! Условия (W5): ровно один вид — прогноз или эталон.
use crate::error::Error;
use serde::Deserialize;
use serde_json::{Map, Value};

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Forecast {
    pub temperature_c: f64,
    pub wind_speed_kmh: f64,
    pub wind_from_deg: f64,
    pub sky: String,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WindRef {
    pub ref_msl: f64,
    /// Рост ветра на км высоты; нет ключа - из климата места (`Weather::climate_place`, W5 v10).
    #[serde(default)]
    pub gain_per_km: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Source {
    Forecast {
        forecast: Forecast,
        quantum_h: f64,
        wind_ref: Option<WindRef>,
        overrides: Map<String, Value>,
    },
    /// Имя пресета (`String`) или словарь ключей пресета (`Object`).
    Preset(Value),
}

/// Как начинается воздух при загрузке места (W5 v2): `Start` (по умолчанию) или `Inflow`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum InflowMode {
    #[default]
    Start,
    Inflow,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Conditions {
    pub source: Source,
    pub start_hour: f64,
    pub speed: f64,
    pub blend_s: Option<f64>,
    pub rebuild: bool,
    pub inflow_mode: InflowMode,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Raw {
    forecast: Option<Forecast>,
    preset: Option<Value>,
    start_hour: Option<f64>,
    speed: Option<f64>,
    quantum_h: Option<f64>,
    wind_ref: Option<WindRef>,
    overrides: Option<Map<String, Value>>,
    blend_s: Option<f64>,
    #[serde(default)]
    rebuild: bool,
    inflow_mode: Option<String>,
}

impl Conditions {
    /// Разбор json; посторонний ключ, оба вида или ни одного, ключ чужого вида — BAD_INPUT.
    pub fn from_json(text: &str) -> Result<Self, Error> {
        let bad = |m: String| Error::bad_input(format!("conditions: {m}"));
        let raw: Raw = serde_json::from_str(text).map_err(|e| bad(e.to_string()))?;
        let start_hour = raw
            .start_hour
            .ok_or_else(|| bad("missing 'start_hour'".into()))?;
        let speed = raw.speed.ok_or_else(|| bad("missing 'speed'".into()))?;
        if !start_hour.is_finite() {
            return Err(bad("start_hour must be finite".into()));
        }
        if !(speed.is_finite() && speed > 0.0) {
            return Err(bad("speed must be > 0".into()));
        }
        if let Some(b) = raw.blend_s
            && !(b.is_finite() && b >= 0.0)
        {
            return Err(bad("blend_s must be >= 0".into()));
        }
        let inflow_mode = match raw.inflow_mode.as_deref() {
            None | Some("start") => InflowMode::Start,
            Some("inflow") => InflowMode::Inflow,
            Some(other) => return Err(bad(format!("inflow_mode '{other}' must be start|inflow"))),
        };
        let source = match (raw.forecast, raw.preset) {
            (Some(_), Some(_)) => return Err(bad("both 'forecast' and 'preset'".into())),
            (None, None) => return Err(bad("neither 'forecast' nor 'preset'".into())),
            (Some(f), None) => {
                if ![f.temperature_c, f.wind_speed_kmh, f.wind_from_deg]
                    .iter()
                    .all(|v| v.is_finite())
                {
                    return Err(bad("forecast: non-finite number".into()));
                }
                let q = raw
                    .quantum_h
                    .ok_or_else(|| bad("missing 'quantum_h'".into()))?;
                if !(q.is_finite() && q > 0.0) {
                    return Err(bad("quantum_h must be > 0".into()));
                }
                if let Some(w) = &raw.wind_ref
                    && !(w.ref_msl.is_finite() && w.gain_per_km.is_none_or(f64::is_finite))
                {
                    return Err(bad("wind_ref: non-finite number".into()));
                }
                Source::Forecast {
                    forecast: f,
                    quantum_h: q,
                    wind_ref: raw.wind_ref,
                    overrides: raw.overrides.unwrap_or_default(),
                }
            }
            (None, Some(p)) => {
                if raw.quantum_h.is_some() || raw.wind_ref.is_some() || raw.overrides.is_some() {
                    return Err(bad(
                        "'quantum_h'/'wind_ref'/'overrides' belong to forecast".into()
                    ));
                }
                if !(p.is_string() || p.is_object()) {
                    return Err(bad("'preset' must be a string or an object".into()));
                }
                Source::Preset(p)
            }
        };
        Ok(Conditions {
            source,
            start_hour,
            speed,
            blend_s: raw.blend_s,
            rebuild: raw.rebuild,
            inflow_mode,
        })
    }
}
