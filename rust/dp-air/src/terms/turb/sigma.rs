//! σ болтанки поля и масштабы вихрей:
//! механика по u* поля и сдвигу, устойчивость Ri, конвекция Ленчова по w*, σ³-сложение,
//! анизотропия MIL-HDBK-1797 (σ_u ≠ σ_v ≠ σ_w), масштабы L_u, L_w с поправкой σ_w/N.
//! Законы и источники — `docs/guide/air-model.md` → «Масштаб 3: возмущения».
use crate::Configs;
use crate::field::case_prepare::LAM_FRAC;
use crate::field::wind_field::{KAPPA, T_HMIX, T_N2, T_SHEAR, T_USTAR, T_WSTAR};
use crate::field::wind_profile::{F_COR, NEUTRAL_BL_K};
use crate::terms::named_json;
use serde_json::Value;

/// Приземный слой — нижняя доля пограничного слоя (≈ 0,1 h, Stull 1988, §1.5): ниже u* болтанки
/// согласован со средним ветром в точке.
pub const SURFACE_FRAC: f64 = 0.1;
/// `σ_v/σ_w = 1 + V_ANISO·(σ_u/σ_w − 1)`: у земли 1,9/1,25 при σ_u/σ_w = 2,4/1,25 (Panofsky &
/// Dutton 1984), выше — к изотропии вместе с σ_u.
pub const V_ANISO: f64 = (1.9 / 1.25 - 1.0) / (2.4 / 1.25 - 1.0);
/// Растяжение масштабов у земли (`taylor_stretch`): высота спада, м (≈ размах крыла), и наибольший
/// множитель.
pub const TAYLOR_H: f64 = 10.0;
pub const TAYLOR_MAX: f64 = 8.0;

/// Коэффициенты болтанки поля: секция `atmosphere` → `turbulence.*`, `lee.*` (запасные значения —
/// как в файле конфига).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TurbCfg {
    /// `turbulence.field_sigma_w_per_ustar`.
    pub sw_per_ustar: f64,
    /// `field_mixing_length_m`.
    pub mix_len: f64,
    /// `field_conv_sigma_u_per_wstar`.
    pub conv_su: f64,
    /// `field_cbl_scale_per_zi`.
    pub cbl_frac: f64,
    /// `lee.field_deficit_attached` / `field_deficit_separated`.
    pub ex0: f64,
    pub ex1: f64,
    /// `lee.field_descent_slope`.
    pub desc: f64,
    /// `lee.field_sigma_u_per_du` / `field_sigma_w_per_du`.
    pub sep_su: f64,
    pub sep_sw: f64,
    /// `lee.field_reverse_per_uh`.
    pub reverse: f64,
    /// `lee.field_burst_per_du`.
    pub burst_per_du: f64,
    /// `lee.field_bubble_length_per_relief`.
    pub bubble_len: f64,
    /// `lee.field_resolved_cells`.
    pub resolved_n0: f64,
    pub resolved_n1: f64,
    /// `lee.field_eddy_scale_per_relief`.
    pub sep_scale: f64,
    /// `lee.burst_threshold` / `burst_width` / `burst_scale_m`; `burst_k = scale_m/burst_scale_m`.
    pub burst_thr: f64,
    pub burst_width: f64,
    pub burst_k: f64,
    /// `lee.rotor_height_fraction`.
    pub rotor_h: f64,
    /// `lee.danger_min_wind_ms` / `danger_full_wind_ms`.
    pub danger_min: f64,
    pub danger_full: f64,
    /// `turbulence.advection_height_m`.
    pub advection_height: f64,
    /// `turbulence.vertical_ratio` (конвективная σ_w аналитики).
    pub vertical_ratio: f64,
    /// `ground.reference_radius_m` / `reference_samples`: отсчёт кромки облаков (`mean_height`).
    pub ground_radius: f64,
    pub ground_samples: i64,
}

impl Default for TurbCfg {
    fn default() -> Self {
        TurbCfg {
            sw_per_ustar: 1.25,
            mix_len: 40.0,
            conv_su: 0.6,
            cbl_frac: 0.22,
            ex0: 0.3,
            ex1: 0.7,
            desc: 0.05,
            sep_su: 0.18,
            sep_sw: 0.14,
            reverse: 0.22,
            burst_per_du: 0.42,
            bubble_len: 2.8,
            resolved_n0: 4.0,
            resolved_n1: 8.0,
            sep_scale: 0.5,
            burst_thr: 0.8,
            burst_width: 1.0,
            burst_k: 45.0 / 120.0,
            rotor_h: 0.4,
            danger_min: 2.0,
            danger_full: 5.0,
            advection_height: 300.0,
            vertical_ratio: 0.7,
            ground_radius: 10_000.0,
            ground_samples: 15,
        }
    }
}

impl TurbCfg {
    pub fn from_configs(c: &Configs) -> Self {
        let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);
        let d = TurbCfg::default();
        let g = |p: &str, dv: f64| atm.pointer(p).and_then(Value::as_f64).unwrap_or(dv);
        let rc = |i: usize, dv: f64| {
            atm.pointer(&format!("/lee/field_resolved_cells/{i}"))
                .and_then(Value::as_f64)
                .unwrap_or(dv)
        };
        let scale = g("/turbulence/scale_m", 45.0);
        TurbCfg {
            sw_per_ustar: g("/turbulence/field_sigma_w_per_ustar", d.sw_per_ustar),
            mix_len: g("/turbulence/field_mixing_length_m", d.mix_len),
            conv_su: g("/turbulence/field_conv_sigma_u_per_wstar", d.conv_su),
            cbl_frac: g("/turbulence/field_cbl_scale_per_zi", d.cbl_frac),
            ex0: g("/lee/field_deficit_attached", d.ex0),
            ex1: g("/lee/field_deficit_separated", d.ex1),
            desc: g("/lee/field_descent_slope", d.desc),
            sep_su: g("/lee/field_sigma_u_per_du", d.sep_su),
            sep_sw: g("/lee/field_sigma_w_per_du", d.sep_sw),
            reverse: g("/lee/field_reverse_per_uh", d.reverse),
            burst_per_du: g("/lee/field_burst_per_du", d.burst_per_du),
            bubble_len: g("/lee/field_bubble_length_per_relief", d.bubble_len),
            resolved_n0: rc(0, d.resolved_n0),
            resolved_n1: rc(1, d.resolved_n1),
            sep_scale: g("/lee/field_eddy_scale_per_relief", d.sep_scale),
            burst_thr: g("/lee/burst_threshold", d.burst_thr),
            burst_width: g("/lee/burst_width", d.burst_width),
            burst_k: scale / g("/lee/burst_scale_m", 120.0),
            rotor_h: g("/lee/rotor_height_fraction", d.rotor_h),
            danger_min: g("/lee/danger_min_wind_ms", d.danger_min),
            danger_full: g("/lee/danger_full_wind_ms", d.danger_full),
            advection_height: g("/turbulence/advection_height_m", d.advection_height),
            vertical_ratio: g("/turbulence/vertical_ratio", d.vertical_ratio),
            ground_radius: g("/ground/reference_radius_m", d.ground_radius),
            ground_samples: g("/ground/reference_samples", d.ground_samples as f64) as i64,
        }
    }
}

/// `smoothstep` эталона.
pub fn smoothstep(from: f64, to: f64, x: f64) -> f64 {
    if (from - to).abs() <= 1.0e-5 * from.abs().max(1.0) {
        return if x <= from { 0.0 } else { 1.0 };
    }
    let s = ((x - from) / (to - from)).clamp(0.0, 1.0);
    s * s * (3.0 - 2.0 * s)
}

/// Результат `sigma`: СКО горизонтали вдоль ветра, вертикали, поперёк ветра (м/с); интегральные
/// масштабы механических вихрей `l_u`, `l_w` (м); доли конвективной дисперсии горизонтали вдоль
/// (`fu_c`) и поперёк (`fv_c`) ветра и их масштаб `l_c` (м; 0 — нет).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Sigma {
    pub s_u: f64,
    pub s_v: f64,
    pub s_w: f64,
    pub l_u: f64,
    pub l_w: f64,
    pub fu_c: f64,
    pub fv_c: f64,
    pub l_c: f64,
}

/// Масштабы MIL-HDBK-1797 (фон Карман), м: ниже 1000 футов `L_w = h`, `L_u = h/(0,177 + 0,000823h)^1,2`
/// (h в футах); от 2000 футов — 2500 футов; между — линейно.
pub fn mil_lw(z: f64) -> f64 {
    let h = (z / 0.3048).max(10.0);
    if h <= 1000.0 {
        return h * 0.3048;
    }
    lerp(1000.0, 2500.0, ((h - 1000.0) / 1000.0).min(1.0)) * 0.3048
}

pub fn mil_lu(z: f64) -> f64 {
    let h = (z / 0.3048).max(10.0);
    if h <= 1000.0 {
        return h / (0.177 + 0.000823 * h).powf(1.2) * 0.3048;
    }
    lerp(1000.0, 2500.0, ((h - 1000.0) / 1000.0).min(1.0)) * 0.3048
}

fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

fn cube_sum(a: f64, b: f64) -> f64 {
    (a * a * a + b * b * b).powf(1.0 / 3.0)
}

/// Растяжение масштабов механических вихрей у земли (`taylor_stretch`): шум переносится одной
/// скоростью `advect` (ветер на 300 м), а вихри приземного слоя — местным ветром `u_loc` (гипотеза
/// Тейлора с местной скоростью переноса — Willis & Deardorff 1976; Kaimal & Finnigan 1994, §2.5).
/// Множитель масштаба — `advect/u_loc` (не больше `TAYLOR_MAX`) с весом `e^(−agl/TAYLOR_H)`.
pub fn taylor_stretch(advect: f64, u_loc: f64, agl: f64) -> f64 {
    let r = (advect / u_loc.max(0.5)).clamp(1.0, TAYLOR_MAX);
    1.0 + (r - 1.0) * (-agl.max(0.0) / TAYLOR_H).exp()
}

/// Профиль Ленчова σ_w ∝ √(1,8 ξ^(2/3) (1 − 0,8ξ)²) (до нормировки на максимум).
pub fn lenschow(xi: f64) -> f64 {
    let a = 1.0 - 0.8 * xi;
    (1.8 * xi.powf(2.0 / 3.0) * a * a).sqrt()
}

/// Нормировка профиля Ленчова: 1/максимум по ξ = 0, 0,01 … 1.
pub fn conv_norm() -> f64 {
    let mut peak = 0.0f64;
    for i in 0..=100 {
        peak = peak.max(lenschow(f64::from(i) / 100.0));
    }
    1.0 / peak.max(1.0e-4)
}

/// `FieldTurbulence.sigma`. `tb` — величины поля (`FieldSet::sample_turb`, 8 каналов);
/// `conv_analytic` — `(σ_u, σ_w)` конвективной болтанки аналитики (берётся, если в поле нет данных
/// о нагреве, `T_HMIX = 0`); `u_pt` — модуль среднего ветра поля в точке (≥ 0): ниже
/// `SURFACE_FRAC·h` u* берётся согласованным с ним — `κ·U/ln(z/z0)`; < 0 — не учитывать.
pub fn sigma(
    cfg: &TurbCfg,
    z0: f64,
    agl: f64,
    tb: &[f32],
    conv_analytic: [f64; 2],
    u_pt: f64,
) -> Sigma {
    let z = agl.max(1.0);
    let h_mix = f64::from(tb[T_HMIX]);
    let ustar = f64::from(tb[T_USTAR]);
    let shear = f64::from(tb[T_SHEAR]);
    // механика: u* стенки гаснет к верху слоя (1 − z/h)^(3/4) (Nieuwstadt 1984); местный сдвиг —
    // длина перемешивания Прандтля–Блэкадара как в решателе, λ = max(λ₀, λ/h·h); h без данных о
    // нагреве — нейтральный слой NEUTRAL_BL_K·u*/f
    let h_bl = if h_mix > 0.0 {
        h_mix
    } else {
        NEUTRAL_BL_K / F_COR * ustar
    };
    let lam = cfg.mix_len.max(LAM_FRAC * h_bl);
    let decay = (1.0 - z / h_bl.max(1.0)).max(0.0).powf(0.75);
    let l_mix = 1.0 / (1.0 / (KAPPA * z) + 1.0 / lam);
    let mut u_wall = ustar * decay;
    if u_pt >= 0.0 {
        // приземный слой: u* из того же лог-закона, что даёт средний ветер
        let u_loc = KAPPA * u_pt / (z.max(2.0 * z0) / z0).ln();
        let sl = smoothstep(0.5, 1.0, z / (SURFACE_FRAC * h_bl).max(1.0));
        u_wall = lerp(u_loc, u_wall, sl);
    }
    let mut u_m = u_wall.max(l_mix * shear);
    // устойчивость: u*_loc ∝ √F(Ri), F = 1/(1 + 5Ri)²
    let n2 = f64::from(tb[T_N2]);
    let mut n_bv = 0.0;
    if n2.is_finite() && n2 > 0.0 {
        let ri = n2 / (shear * shear).max(1.0e-6);
        u_m /= 1.0 + 5.0 * ri;
        n_bv = n2.sqrt();
    }
    let sw_m = cfg.sw_per_ustar * u_m;
    let h_ft = z / 0.3048;
    let mut aniso = 1.0;
    if h_ft < 1000.0 {
        aniso = 1.0 / (0.177 + 0.000823 * h_ft).powf(0.4);
    }
    // анизотропия: σ_u/σ_w по MIL-HDBK-1797; поперёк ветра — та же доля пути к изотропии
    let su_m = sw_m * aniso;
    let sv_m = sw_m * (1.0 + V_ANISO * (aniso - 1.0));
    // конвекция: Lenschow et al. (1980) по w* поля; нет данных о нагреве — аналитика (погода)
    let (mut su_c, mut sw_c) = (0.0, 0.0);
    let wstar = f64::from(tb[T_WSTAR]);
    let mut l_w = mil_lw(z);
    let mut l_u = mil_lu(z);
    let mut l_c = 0.0;
    if h_mix > 0.0 {
        let xi = z / h_mix;
        if xi < 1.0 {
            su_c = cfg.conv_su * wstar;
            // шум несёт только вертикаль мельче масштаба конвективных вихрей: (L_w/L_cbl)^(1/3)
            let l_cbl = cfg.cbl_frac * h_mix;
            sw_c = wstar * 1.8f64.sqrt() * xi.powf(1.0 / 3.0) * (1.0 - 0.8 * xi);
            sw_c *= (l_w / l_cbl).min(1.0).powf(1.0 / 3.0);
            // горизонталь конвективных вихрей — масштаба слоя (пик на ~1,5 z_i), не высоты
            l_c = l_cbl;
        }
    } else {
        su_c = conv_analytic[0];
        sw_c = conv_analytic[1];
    }
    // σ³ = σ_m³ + σ_c³ (Panofsky et al. 1977)
    let s_u = cube_sum(su_m, su_c);
    let s_v = cube_sum(sv_m, su_c);
    let s_w = cube_sum(sw_m, sw_c);
    let (mut fu_c, mut fv_c) = (0.0, 0.0);
    if l_c > 0.0 {
        fu_c = if s_u > 1.0e-4 {
            1.0 - su_m * su_m / (s_u * s_u).max(1.0e-9)
        } else {
            0.0
        };
        fv_c = if s_v > 1.0e-4 {
            1.0 - sv_m * sv_m / (s_v * s_v).max(1.0e-9)
        } else {
            0.0
        };
    }
    // масштабы: в устойчивом воздухе вихри не крупнее σ_w/N (Hunt, Kaimal & Gaynor 1985)
    if n_bv > 0.0 && s_w > 1.0e-3 {
        let lb = s_w / n_bv;
        l_u = 1.0 / (1.0 / l_u + 1.0 / lb);
        l_w = 1.0 / (1.0 / l_w + 1.0 / lb);
        if l_c > 0.0 {
            l_c = 1.0 / (1.0 / l_c + 1.0 / lb);
        }
    }
    // эталона отдаёт (s_u, s_w, l_u, l_w) как `Vector4` — f32
    let f = |x: f64| f64::from(x as f32);
    Sigma {
        s_u: f(s_u),
        s_v,
        s_w: f(s_w),
        l_u: f(l_u),
        l_w: f(l_w),
        fu_c,
        fv_c,
        l_c,
    }
}
