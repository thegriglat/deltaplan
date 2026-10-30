//! Конфиг фаз: секция `atmosphere` → `air_phase` (все константы фаз — там, в коде их нет).
//! Читается разбором текста json (как `ZiCfg`); нет ключа — `BAD_INPUT` с путём ключа.
use crate::{Configs, Error};
use serde_json::Value;

/// Ось сильного D (`classifier.d_strong_axis`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DStrongAxis {
    /// Без сильного D.
    None,
    /// Закон `N_c(U)` (AP-13).
    NcLaw,
    /// По числу Фруда.
    Fr,
    /// По `U_sat/N` (по умолчанию в эталоне).
    UOverN,
}

/// `air_phase.classifier`.
#[derive(Clone, Debug, PartialEq)]
pub struct ClassifierCfg {
    /// Ось штиля: `true` — U10, `false` — Fr.
    pub h_axis_u10: bool,
    pub h_c: f64,
    pub h_w_dec: f64,
    pub d_strong_axis: DStrongAxis,
    pub d_strong_nc0: f64,
    pub d_strong_p: f64,
    pub d_strong_c: f64,
    pub d_strong_w_dec: f64,
    pub d_fr_c: f64,
    pub d_w_dec: f64,
    pub d_local: bool,
    pub d_local_ramp_m: f64,
    pub c_w_ms: f64,
    pub c_w_dec: f64,
    pub b_env_angle_deg: f64,
    pub b_depth_m: f64,
    pub b_heat_lo: f64,
    pub b_heat_hi: f64,
    pub b_steep: f64,
    pub b_heat_steep_k: f64,
    pub f_zil_c: f64,
    pub f_w_dec: f64,
    pub f_wstar_over_usat: f64,
    pub fr_inf: f64,
    pub n_layer_m: f64,
    pub smooth_cells: f64,
    pub smooth_truncate: f64,
    pub smooth_min_cells: f64,
    pub env_max_sweeps: usize,
    pub c_sigma_max_cells: f64,
    pub freeze_w: f64,
    pub omega_fr_lo: f64,
    pub omega_fr_hi: f64,
    pub omega_u10_lo: f64,
    pub omega_u10_hi: f64,
    pub omega_w_dec: f64,
    pub omega_band: f64,
    pub omega_snap: f64,
}

/// `air_phase.d` (сильное D, слои Лапласа).
#[derive(Clone, Debug, PartialEq)]
pub struct DCfg {
    pub base_pct: f64,
    pub dz_layer_m: f64,
    pub max_layers: usize,
    pub sor_iters: usize,
    pub sor_omega: f64,
}

/// `air_phase.a` (линейная теория; для RW-6l).
#[derive(Clone, Debug, PartialEq)]
pub struct ACfg {
    pub damp_m: f64,
    pub cap_frac: f64,
    pub uref_min: f64,
    pub jh_iters: usize,
    pub jh_ell0_m: f64,
    pub jh_hm0_m: f64,
}

/// `air_phase.f`, `.b`, `.g` (то, что читает `params`; для RW-6l/6m).
#[derive(Clone, Debug, PartialEq)]
pub struct MechCfg {
    pub bubble_reverse: f64,
    pub slope_len_m: f64,
    pub ana_delta_min_m: f64,
    pub ana_delta_frac: f64,
    pub uml_levels: usize,
    pub uml_min_ms: f64,
    pub g_top_l: f64,
    pub g_member_frac: f64,
}

/// `air_phase.f` (подобие слоя перемешивания [LWP80], для статистики F).
#[derive(Clone, Debug, PartialEq)]
pub struct FCfg {
    pub sigw_a: f64,
    pub sigw_b: f64,
    pub w3_a: f64,
}

/// `air_phase.g` (вечерний сток: Прандтль, D8, гидравлический слой).
#[derive(Clone, Debug, PartialEq)]
pub struct GCfg {
    pub mean_heat_max_wm2: f64,
    pub n_min: f64,
    pub k_m2s: f64,
    pub sin_min: f64,
    pub dth_max_k: f64,
    pub u_max_ms: f64,
    pub c_d: f64,
    pub sin_floor: f64,
    pub d_max_m: f64,
    pub relief_r_m: f64,
    pub w_dec: f64,
    pub smooth_cells: f64,
    pub zg_min_m: f64,
}

/// Блок `air_phase` целиком (то, что нужно фазам 1–3).
#[derive(Clone, Debug, PartialEq)]
pub struct PhaseCfg {
    /// Высоты над рельефом линейной теории, м.
    pub agl_levels_m: Vec<f64>,
    pub classifier: ClassifierCfg,
    pub d: DCfg,
    pub a: ACfg,
    pub mech: MechCfg,
    pub f: FCfg,
    pub g: GCfg,
    /// `h.spread_frac`: разброс штиля в долях `U_sat` (статистика).
    pub h_spread_frac: f64,
    /// `nonconv.mech_w`: порог веса H + D колонны запасного пути.
    pub nonconv_mech_w: f64,
}

struct Get<'a>(&'a Value);

impl Get<'_> {
    fn f(&self, path: &str) -> Result<f64, Error> {
        self.0.pointer(path).and_then(Value::as_f64).ok_or_else(|| {
            Error::bad_input(format!("config 'atmosphere': нет числа air_phase{path}"))
        })
    }
    fn u(&self, path: &str) -> Result<usize, Error> {
        Ok(self.f(path)?.max(0.0) as usize)
    }
    fn b(&self, path: &str) -> Result<bool, Error> {
        self.0
            .pointer(path)
            .and_then(Value::as_bool)
            .ok_or_else(|| {
                Error::bad_input(format!("config 'atmosphere': нет bool air_phase{path}"))
            })
    }
    fn s(&self, path: &str) -> Result<&str, Error> {
        self.0.pointer(path).and_then(Value::as_str).ok_or_else(|| {
            Error::bad_input(format!("config 'atmosphere': нет строки air_phase{path}"))
        })
    }
}

impl PhaseCfg {
    /// Из набора конфигов W5 (секция `atmosphere`).
    pub fn from_configs(cfg: &Configs) -> Result<Self, Error> {
        let text = cfg
            .get("atmosphere")
            .ok_or_else(|| Error::bad_input("config 'atmosphere' не передан"))?;
        Self::from_json(text)
    }

    /// Из текста секция `atmosphere`.
    pub fn from_json(text: &str) -> Result<Self, Error> {
        let v: Value = serde_json::from_str(text)
            .map_err(|e| Error::bad_input(format!("config 'atmosphere': {e}")))?;
        let root = v
            .get("air_phase")
            .ok_or_else(|| Error::bad_input("config 'atmosphere': нет блока air_phase"))?;
        Self::from_value(root)
    }

    /// Из значения блока `air_phase`.
    pub fn from_value(root: &Value) -> Result<Self, Error> {
        let g = Get(root);
        let agl_levels_m = root
            .get("agl_levels_m")
            .and_then(Value::as_array)
            .ok_or_else(|| Error::bad_input("config 'atmosphere': нет air_phase.agl_levels_m"))?
            .iter()
            .map(|x| {
                x.as_f64()
                    .ok_or_else(|| Error::bad_input("air_phase.agl_levels_m: не число"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let axis = match g.s("/classifier/d_strong_axis")? {
            "none" => DStrongAxis::None,
            "nc_law" => DStrongAxis::NcLaw,
            "fr" => DStrongAxis::Fr,
            _ => DStrongAxis::UOverN,
        };
        let c = |k: &str| g.f(&format!("/classifier/{k}"));
        let classifier = ClassifierCfg {
            h_axis_u10: g.s("/classifier/h_axis")? == "u10",
            h_c: c("h_c")?,
            h_w_dec: c("h_w_dec")?,
            d_strong_axis: axis,
            d_strong_nc0: c("d_strong_nc0")?,
            d_strong_p: c("d_strong_p")?,
            d_strong_c: c("d_strong_c")?,
            d_strong_w_dec: c("d_strong_w_dec")?,
            d_fr_c: c("d_fr_c")?,
            d_w_dec: c("d_w_dec")?,
            d_local: g.b("/classifier/d_local")?,
            d_local_ramp_m: c("d_local_ramp_m")?,
            c_w_ms: c("c_w_ms")?,
            c_w_dec: c("c_w_dec")?,
            b_env_angle_deg: c("b_env_angle_deg")?,
            b_depth_m: c("b_depth_m")?,
            b_heat_lo: c("b_heat_lo")?,
            b_heat_hi: c("b_heat_hi")?,
            b_steep: c("b_steep")?,
            b_heat_steep_k: c("b_heat_steep_k")?,
            f_zil_c: c("f_zil_c")?,
            f_w_dec: c("f_w_dec")?,
            f_wstar_over_usat: c("f_wstar_over_usat")?,
            fr_inf: c("fr_inf")?,
            n_layer_m: c("n_layer_m")?,
            smooth_cells: c("smooth_cells")?,
            smooth_truncate: c("smooth_truncate")?,
            smooth_min_cells: c("smooth_min_cells")?,
            env_max_sweeps: g.u("/classifier/env_max_sweeps")?,
            c_sigma_max_cells: c("c_sigma_max_cells")?,
            freeze_w: c("freeze_w")?,
            omega_fr_lo: c("omega_fr_lo")?,
            omega_fr_hi: c("omega_fr_hi")?,
            omega_u10_lo: c("omega_u10_lo")?,
            omega_u10_hi: c("omega_u10_hi")?,
            omega_w_dec: c("omega_w_dec")?,
            omega_band: c("omega_band")?,
            omega_snap: c("omega_snap")?,
        };
        let d = DCfg {
            base_pct: g.f("/d/base_pct")?,
            dz_layer_m: g.f("/d/dz_layer_m")?,
            max_layers: g.u("/d/max_layers")?,
            sor_iters: g.u("/d/sor_iters")?,
            sor_omega: g.f("/d/sor_omega")?,
        };
        let a = ACfg {
            damp_m: g.f("/a/damp_m")?,
            cap_frac: g.f("/a/cap_frac")?,
            uref_min: g.f("/a/uref_min")?,
            jh_iters: g.u("/a/jh_iters")?,
            jh_ell0_m: g.f("/a/jh_ell0_m")?,
            jh_hm0_m: g.f("/a/jh_hm0_m")?,
        };
        let mech = MechCfg {
            bubble_reverse: g.f("/b/bubble_reverse")?,
            slope_len_m: g.f("/f/slope_len_m")?,
            ana_delta_min_m: g.f("/f/ana_delta_min_m")?,
            ana_delta_frac: g.f("/f/ana_delta_frac")?,
            uml_levels: g.u("/f/uml_levels")?,
            uml_min_ms: g.f("/f/uml_min_ms")?,
            g_top_l: g.f("/g/top_l")?,
            g_member_frac: g.f("/g/member_frac")?,
        };
        let f = FCfg {
            sigw_a: g.f("/f/sigw_a")?,
            sigw_b: g.f("/f/sigw_b")?,
            w3_a: g.f("/f/w3_a")?,
        };
        let gg = |k: &str| g.f(&format!("/g/{k}"));
        let gc = GCfg {
            mean_heat_max_wm2: gg("mean_heat_max_wm2")?,
            n_min: gg("n_min")?,
            k_m2s: gg("k_m2s")?,
            sin_min: gg("sin_min")?,
            dth_max_k: gg("dth_max_k")?,
            u_max_ms: gg("u_max_ms")?,
            c_d: gg("c_d")?,
            sin_floor: gg("sin_floor")?,
            d_max_m: gg("d_max_m")?,
            relief_r_m: gg("relief_r_m")?,
            w_dec: gg("w_dec")?,
            smooth_cells: gg("smooth_cells")?,
            zg_min_m: gg("zg_min_m")?,
        };
        Ok(PhaseCfg {
            agl_levels_m,
            classifier,
            d,
            a,
            mech,
            f,
            g: gc,
            h_spread_frac: g.f("/h/spread_frac")?,
            nonconv_mech_w: g.f("/nonconv/mech_w")?,
        })
    }
}
