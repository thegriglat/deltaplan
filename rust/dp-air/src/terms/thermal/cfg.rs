//! Конфиг термиков: секция `atmosphere` → `thermal`, `clouds.linger_s`, `cirrus.sun_block`,
//! `ground`, `turbulence.edge_*`. Запасные значения — как в секция `atmosphere`.
use crate::Configs;
use crate::terms::named_json;
use serde_json::Value;

/// Числа `thermal.*`, нужные жизни и профилю термика.
#[derive(Clone, Debug, PartialEq)]
pub struct ThermalCfg {
    pub ring_sink_factor: f64,
    pub profile_cutoff_radii: f64,
    pub radius_min_factor: f64,
    pub ground_ramp_m: f64,
    pub top_taper_m: f64,
    pub suck_depth_m: f64,
    pub in_cloud_mean_frac: f64,
    pub min_depth_m: f64,
    pub rise_factor: f64,
    pub rise_min_ms: f64,
    pub drift_factor: f64,
    pub drift_delay_s: f64,
    pub max_lean_deg: f64,
    pub grow_s: [f64; 2],
    pub mature_s: [f64; 2],
    pub decay_s: [f64; 2],
    pub gap_s: [f64; 2],
    pub source_candidates: usize,
    pub sun_min: f64,
    pub source_frequency_exponent: f64,
    pub sun_strength_exponent: f64,
    pub cloud_shade_factor: f64,
    pub insolation_strength_exponent: f64,
    pub cb_min_strength_frac: f64,
    pub cb_strength_factor: f64,
    pub cb_suck: f64,
    pub cb_mature_factor: f64,
    pub generation_radius_m: f64,
    pub physics_radius_m: f64,
    pub refresh_interval_s: f64,
    pub bucket_m: f64,
    pub street_spacing_factor: f64,
    pub street_min_wind_ms: f64,
    pub street_full_wind_ms: f64,
    pub street_cloud_stretch: f64,
    /// `clouds.linger_s`: сколько живёт облако после конца термика, с.
    pub cloud_linger_s: f64,
    /// `cirrus.sun_block`.
    pub cirrus_block: f64,
    /// `ground.reference_radius_m`, `ground.reference_samples`: отсчёт кромки облаков.
    pub ref_radius_m: f64,
    pub ref_samples: usize,
    /// `turbulence.edge_factor`, `turbulence.edge_width`: край термика (σ).
    pub edge_factor: f64,
    pub edge_width: f64,
    /// `clouds.sun_elevation_deg`, `clouds.sun_azimuth_deg`: солнце «по умолчанию».
    pub sun_elevation_deg: f64,
    pub sun_azimuth_deg: f64,
}

impl Default for ThermalCfg {
    fn default() -> Self {
        ThermalCfg {
            ring_sink_factor: 1.6,
            profile_cutoff_radii: 2.5,
            radius_min_factor: 0.45,
            ground_ramp_m: 150.0,
            top_taper_m: 120.0,
            suck_depth_m: 250.0,
            in_cloud_mean_frac: 0.25,
            min_depth_m: 400.0,
            rise_factor: 1.0,
            rise_min_ms: 1.0,
            drift_factor: 0.85,
            drift_delay_s: 60.0,
            max_lean_deg: 60.0,
            grow_s: [120.0, 240.0],
            mature_s: [300.0, 720.0],
            decay_s: [150.0, 300.0],
            gap_s: [60.0, 300.0],
            source_candidates: 8,
            sun_min: 0.35,
            source_frequency_exponent: 1.0,
            sun_strength_exponent: 1.0,
            cloud_shade_factor: 0.6,
            insolation_strength_exponent: 1.5,
            cb_min_strength_frac: 0.55,
            cb_strength_factor: 1.4,
            cb_suck: 0.4,
            cb_mature_factor: 2.5,
            generation_radius_m: 20000.0,
            physics_radius_m: 6000.0,
            refresh_interval_s: 1.0,
            bucket_m: 500.0,
            street_spacing_factor: 2.5,
            street_min_wind_ms: 4.0,
            street_full_wind_ms: 8.0,
            street_cloud_stretch: 0.6,
            cloud_linger_s: 240.0,
            cirrus_block: 0.6,
            ref_radius_m: 10000.0,
            ref_samples: 15,
            edge_factor: 0.35,
            edge_width: 0.45,
            sun_elevation_deg: 52.0,
            sun_azimuth_deg: 200.0,
        }
    }
}

impl ThermalCfg {
    pub fn from_configs(c: &Configs) -> Self {
        let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);
        Self::from_json(&atm)
    }

    pub fn from_json(atm: &Value) -> Self {
        let d = ThermalCfg::default();
        let g = |p: &str, dv: f64| atm.pointer(p).and_then(Value::as_f64).unwrap_or(dv);
        let pair = |p: &str, dv: [f64; 2]| {
            let a = atm.pointer(p).and_then(Value::as_array);
            match a {
                Some(a) if a.len() == 2 => [
                    a[0].as_f64().unwrap_or(dv[0]),
                    a[1].as_f64().unwrap_or(dv[1]),
                ],
                _ => dv,
            }
        };
        let t = |k: &str, dv: f64| g(&format!("/thermal/{k}"), dv);
        ThermalCfg {
            ring_sink_factor: t("ring_sink_factor", d.ring_sink_factor),
            profile_cutoff_radii: t("profile_cutoff_radii", d.profile_cutoff_radii),
            radius_min_factor: t("radius_min_factor", d.radius_min_factor),
            ground_ramp_m: t("ground_ramp_m", d.ground_ramp_m),
            top_taper_m: t("top_taper_m", d.top_taper_m),
            suck_depth_m: t("suck_depth_m", d.suck_depth_m),
            in_cloud_mean_frac: t("in_cloud_mean_frac", d.in_cloud_mean_frac),
            min_depth_m: t("min_depth_m", d.min_depth_m),
            rise_factor: t("rise_factor", d.rise_factor),
            rise_min_ms: t("rise_min_ms", d.rise_min_ms),
            drift_factor: t("drift_factor", 0.0),
            drift_delay_s: t("drift_delay_s", 0.0),
            max_lean_deg: t("max_lean_deg", d.max_lean_deg),
            grow_s: pair("/thermal/grow_s", d.grow_s),
            mature_s: pair("/thermal/mature_s", d.mature_s),
            decay_s: pair("/thermal/decay_s", d.decay_s),
            gap_s: pair("/thermal/gap_s", d.gap_s),
            source_candidates: t("source_candidates", d.source_candidates as f64) as usize,
            sun_min: t("sun_min", d.sun_min),
            source_frequency_exponent: t("source_frequency_exponent", d.source_frequency_exponent),
            sun_strength_exponent: t("sun_strength_exponent", d.sun_strength_exponent),
            cloud_shade_factor: t("cloud_shade_factor", d.cloud_shade_factor),
            insolation_strength_exponent: t(
                "insolation_strength_exponent",
                d.insolation_strength_exponent,
            ),
            cb_min_strength_frac: t("cb_min_strength_frac", d.cb_min_strength_frac),
            cb_strength_factor: t("cb_strength_factor", d.cb_strength_factor),
            cb_suck: t("cb_suck", d.cb_suck),
            cb_mature_factor: t("cb_mature_factor", d.cb_mature_factor),
            generation_radius_m: t("generation_radius_m", d.generation_radius_m),
            physics_radius_m: t("physics_radius_m", d.physics_radius_m),
            refresh_interval_s: t("refresh_interval_s", d.refresh_interval_s),
            bucket_m: t("bucket_m", d.bucket_m).max(1.0),
            street_spacing_factor: t("street_spacing_factor", d.street_spacing_factor),
            street_min_wind_ms: t("street_min_wind_ms", d.street_min_wind_ms),
            street_full_wind_ms: t("street_full_wind_ms", d.street_full_wind_ms),
            street_cloud_stretch: t("street_cloud_stretch", d.street_cloud_stretch),
            cloud_linger_s: g("/clouds/linger_s", d.cloud_linger_s),
            cirrus_block: g("/cirrus/sun_block", d.cirrus_block),
            ref_radius_m: g("/ground/reference_radius_m", d.ref_radius_m),
            ref_samples: g("/ground/reference_samples", d.ref_samples as f64) as usize,
            edge_factor: g("/turbulence/edge_factor", d.edge_factor),
            edge_width: g("/turbulence/edge_width", d.edge_width),
            sun_elevation_deg: g("/clouds/sun_elevation_deg", d.sun_elevation_deg),
            sun_azimuth_deg: g("/clouds/sun_azimuth_deg", d.sun_azimuth_deg),
        }
    }

    /// `cb_factor`: `max(cb_mature_factor, 1)`.
    pub fn cb_factor(&self) -> f64 {
        self.cb_mature_factor.max(1.0)
    }
}
