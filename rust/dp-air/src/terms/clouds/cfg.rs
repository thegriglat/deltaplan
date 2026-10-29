//! Конфиги облаков: `atmosphere.json → cloud_field`, подсос и поток в облаке (запасные значения —
//! как в `configs/atmosphere.json`).
use crate::Configs;
use crate::terms::named_json;
use serde_json::Value;

/// `cloud_field` (CLF-К5).
#[derive(Clone, Debug, PartialEq)]
pub struct FieldCfg {
    pub enabled: bool,
    pub step_s: f64,
    pub spinup_s: f64,
    pub depth_max_m: f64,
    pub edge_fade_m: f64,
    pub input_blend_s: f64,
    pub tau_form_s: f64,
    pub tau_life_s: f64,
    pub tau_evap_s: f64,
    pub evap_depth_ref_m: f64,
    pub tau_deepen_s: f64,
    pub tau_overdev_s: f64,
    pub overdev_ref_frac: f64,
    pub tau_stage_s: f64,
    pub overshoot_flux_frac: f64,
    pub w_updraft_k: f64,
    pub w_updraft_min_ms: f64,
    pub k_moist_max: f64,
    pub oro_rise_s: f64,
    pub oro_ramp_m: f64,
    pub oro_w_ref_ms: f64,
    pub rise_w_k: f64,
    pub advect_cells: f64,
    pub cover_min: f64,
    pub shade_depth_m: f64,
    pub depth_day_default_m: f64,
}

impl Default for FieldCfg {
    fn default() -> Self {
        FieldCfg {
            enabled: true,
            step_s: 20.0,
            spinup_s: 2400.0,
            depth_max_m: 2500.0,
            edge_fade_m: 2000.0,
            input_blend_s: 60.0,
            tau_form_s: 240.0,
            tau_life_s: 900.0,
            tau_evap_s: 1200.0,
            evap_depth_ref_m: 1000.0,
            tau_deepen_s: 600.0,
            tau_overdev_s: 1800.0,
            overdev_ref_frac: 0.1,
            tau_stage_s: 600.0,
            overshoot_flux_frac: 0.2,
            w_updraft_k: 0.5,
            w_updraft_min_ms: 0.3,
            k_moist_max: 3.0,
            oro_rise_s: 120.0,
            oro_ramp_m: 150.0,
            oro_w_ref_ms: 1.0,
            rise_w_k: 0.5,
            advect_cells: 0.8,
            cover_min: 0.01,
            shade_depth_m: 60.0,
            depth_day_default_m: 800.0,
        }
    }
}

impl FieldCfg {
    pub fn from_configs(c: &Configs) -> Self {
        let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);
        let d = FieldCfg::default();
        let g = |k: &str, dv: f64| {
            atm.pointer(&format!("/cloud_field/{k}"))
                .and_then(Value::as_f64)
                .unwrap_or(dv)
        };
        FieldCfg {
            enabled: atm
                .pointer("/cloud_field/enabled")
                .and_then(Value::as_bool)
                .unwrap_or(d.enabled),
            step_s: g("step_s", d.step_s),
            spinup_s: g("spinup_s", d.spinup_s),
            depth_max_m: g("depth_max_m", d.depth_max_m),
            edge_fade_m: g("edge_fade_m", d.edge_fade_m),
            input_blend_s: g("input_blend_s", d.input_blend_s),
            tau_form_s: g("tau_form_s", d.tau_form_s),
            tau_life_s: g("tau_life_s", d.tau_life_s),
            tau_evap_s: g("tau_evap_s", d.tau_evap_s),
            evap_depth_ref_m: g("evap_depth_ref_m", d.evap_depth_ref_m),
            tau_deepen_s: g("tau_deepen_s", d.tau_deepen_s),
            tau_overdev_s: g("tau_overdev_s", d.tau_overdev_s),
            overdev_ref_frac: g("overdev_ref_frac", d.overdev_ref_frac),
            tau_stage_s: g("tau_stage_s", d.tau_stage_s),
            overshoot_flux_frac: g("overshoot_flux_frac", d.overshoot_flux_frac),
            w_updraft_k: g("w_updraft_k", d.w_updraft_k),
            w_updraft_min_ms: g("w_updraft_min_ms", d.w_updraft_min_ms),
            k_moist_max: g("k_moist_max", d.k_moist_max),
            oro_rise_s: g("oro_rise_s", d.oro_rise_s),
            oro_ramp_m: g("oro_ramp_m", d.oro_ramp_m),
            oro_w_ref_ms: g("oro_w_ref_ms", d.oro_w_ref_ms),
            rise_w_k: g("rise_w_k", d.rise_w_k),
            advect_cells: g("advect_cells", d.advect_cells),
            cover_min: g("cover_min", d.cover_min),
            shade_depth_m: g("shade_depth_m", d.shade_depth_m),
            depth_day_default_m: g("depth_day_default_m", d.depth_day_default_m),
        }
    }
}

/// Подсос, плотность и поток в облаке (`CloudPhysics.setup`, `Atmosphere._in_cloud_*`).
#[derive(Clone, Debug, PartialEq)]
pub struct PhysCfg {
    pub suck_boost: f64,
    pub size_min: f64,
    pub size_full: f64,
    pub in_cloud_frac: f64,
    pub cover_min: f64,
    /// Среднее `height_to_width`.
    pub hw: f64,
    /// Ячейка сетки Cb-объектов: `clouds.width_max_m`.
    pub cell: f64,
    pub max_distance_m: f64,
    pub depth_max: f64,
    pub in_cloud_ms: f64,
    pub in_cloud_eject_ms: f64,
    /// `turbulence.scale_m / in_cloud_scale_m`.
    pub in_cloud_scale_k: f64,
    pub advection_height_m: f64,
    pub physics_radius_m: f64,
}

impl Default for PhysCfg {
    fn default() -> Self {
        PhysCfg {
            suck_boost: 0.6,
            size_min: 700.0,
            size_full: 1600.0,
            in_cloud_frac: 0.8,
            cover_min: 0.1,
            hw: 0.675,
            cell: 1800.0,
            max_distance_m: 20000.0,
            depth_max: 2500.0,
            in_cloud_ms: 3.5,
            in_cloud_eject_ms: 3.0,
            in_cloud_scale_k: 3.0,
            advection_height_m: 100.0,
            physics_radius_m: 6000.0,
        }
    }
}

impl PhysCfg {
    pub fn from_configs(c: &Configs) -> Self {
        let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);
        let d = PhysCfg::default();
        let g = |p: &str, dv: f64| atm.pointer(p).and_then(Value::as_f64).unwrap_or(dv);
        let pair = |p: &str, dv: [f64; 2]| {
            atm.pointer(p)
                .and_then(Value::as_array)
                .filter(|a| a.len() >= 2)
                .map_or(dv, |a| {
                    [
                        a[0].as_f64().unwrap_or(dv[0]),
                        a[1].as_f64().unwrap_or(dv[1]),
                    ]
                })
        };
        let sz = pair("/thermal/suck_size_m", [d.size_min, d.size_full]);
        let hw = pair("/clouds/height_to_width", [0.45, 0.9]);
        let scale = g("/turbulence/scale_m", 45.0);
        let in_scale = g("/turbulence/in_cloud_scale_m", 15.0);
        PhysCfg {
            suck_boost: g("/thermal/suck_boost", d.suck_boost),
            size_min: sz[0],
            size_full: sz[1],
            in_cloud_frac: g("/thermal/in_cloud_frac", d.in_cloud_frac),
            cover_min: g("/thermal/cloud_cover_min", d.cover_min),
            hw: (0.5 * (hw[0] + hw[1])).max(0.1),
            cell: g("/clouds/width_max_m", d.cell),
            max_distance_m: g("/clouds/max_distance_m", d.max_distance_m),
            depth_max: g("/cloud_field/depth_max_m", d.depth_max),
            in_cloud_ms: g("/turbulence/in_cloud_ms", d.in_cloud_ms),
            in_cloud_eject_ms: g("/turbulence/in_cloud_eject_ms", d.in_cloud_eject_ms),
            in_cloud_scale_k: scale / in_scale,
            advection_height_m: g("/turbulence/advection_height_m", d.advection_height_m),
            physics_radius_m: g("/thermal/physics_radius_m", d.physics_radius_m),
        }
    }
}
