//! Профиль ветра притока по высоте: перенос `WindProfile` (C2 v4–v5). U(z) = U10·(z/10)^α до
//! z_sat, выше — постоянный; α — по классу устойчивости Паскуилла — Тёрнера (Turner 1964,
//! EPA-454/R-99-005) и показателям Irwin 1979; z_sat = z_sat_frac·h, h = 0,3·u*/f, для устойчивых
//! E, F — не больше 0,4·√(u*·L/f), L — Golder 1972.

/// Нижний предел U10 для z_sat, м/с (порог трогания анемометра; без деления на ноль).
pub const U10_MIN: f64 = 0.5;
/// Высота солнца, ниже которой «ночь» Тёрнера, градусы.
pub const NIGHT_SUN_DEG: f64 = 8.0;
/// Показатели степенного профиля A–F, Irwin 1979 (сельская местность).
pub const IRWIN_RURAL: [f64; 6] = [0.07, 0.07, 0.10, 0.15, 0.35, 0.55];
/// Тёрнер: строки — скорость на 10 м в узлах, столбцы — NRI 4, 3, 2, 1, 0, −1, −2; значения —
/// класс 1 (A) … 7 (G); G считается F.
const TURNER: [[u8; 7]; 9] = [
    [1, 1, 2, 3, 4, 6, 7],
    [1, 2, 2, 3, 4, 6, 7],
    [1, 2, 3, 4, 4, 5, 6],
    [2, 2, 3, 4, 4, 5, 6],
    [2, 2, 3, 4, 4, 4, 5],
    [2, 3, 3, 4, 4, 4, 5],
    [3, 3, 4, 4, 4, 4, 5],
    [3, 3, 4, 4, 4, 4, 4],
    [3, 4, 4, 4, 4, 4, 4],
];
const KT_EDGES: [f64; 8] = [1.5, 3.5, 5.5, 6.5, 7.5, 9.5, 10.5, 11.5];
const MS_PER_KT: f64 = 0.514444;
/// Нейтральный класс D (индекс 0..5).
pub const D: usize = 3;
/// Golder 1972: (a, b) в 1/L = a + b·lg z0, классы A–F.
const GOLDER: [[f64; 2]; 6] = [
    [-0.096, 0.029],
    [-0.037, 0.029],
    [-0.002, 0.018],
    [0.0, 0.0],
    [0.004, -0.018],
    [0.035, -0.036],
];
/// Von Kármán и толщина нейтрального слоя (`AirCase.KAPPA`, `NEUTRAL_BL_K`).
pub const KAPPA: f64 = 0.4;
pub const NEUTRAL_BL_K: f64 = 0.3;
/// Параметр Кориолиса 51° с. ш., 1/с (`AirCase.F_COR`).
pub const F_COR: f64 = 1.13e-4;

/// Параметры из `configs/atmosphere.json` → `wind`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindProfileCfg {
    /// `shear_exponent_neutral` (α_N класса D).
    pub alpha_n: f64,
    pub z_sat_frac: f64,
}

impl Default for WindProfileCfg {
    fn default() -> Self {
        WindProfileCfg {
            alpha_n: 0.24,
            z_sat_frac: 0.3,
        }
    }
}

/// Индекс радиации Тёрнера: высота солнца (°) и облачность 0..1 → −2..4.
pub fn net_radiation_index(sun_elev_deg: f64, cover: f64) -> i32 {
    if cover >= 1.0 {
        return 0;
    }
    if sun_elev_deg < NIGHT_SUN_DEG {
        return if cover <= 0.4 { -2 } else { -1 };
    }
    let mut ic = 1;
    if sun_elev_deg > 60.0 {
        ic = 4;
    } else if sun_elev_deg > 35.0 {
        ic = 3;
    } else if sun_elev_deg > 15.0 {
        ic = 2;
    }
    if cover > 0.5 {
        ic = (ic - 2).max(1);
    }
    ic
}

/// Класс устойчивости 0..5 (A..F) по ветру на 10 м (м/с), высоте солнца (°) и облачности 0..1.
pub fn stability_class(u10: f64, sun_elev_deg: f64, cover: f64) -> usize {
    let kt = u10.max(0.0) / MS_PER_KT;
    let row = KT_EDGES.iter().filter(|&&e| kt >= e).count();
    let nri = net_radiation_index(sun_elev_deg, cover);
    (TURNER[row][(4 - nri) as usize].min(6) - 1) as usize
}

/// Показатель степенного профиля по устойчивости.
pub fn alpha(cfg: &WindProfileCfg, u10: f64, sun_elev_deg: f64, cover: f64) -> f64 {
    let r = IRWIN_RURAL[stability_class(u10, sun_elev_deg, cover)] / IRWIN_RURAL[D];
    cfg.alpha_n * r
}

/// 1/L (длина Обухова) по классу 0..5 и z0 — Golder 1972.
pub fn obukhov_inv(cls: usize, z0: f64) -> f64 {
    GOLDER[cls][0] + GOLDER[cls][1] * z0.ln() / 10f64.ln()
}

/// Толщина слоя для насыщения, м: 0,3·u*/f; для устойчивых E, F — не больше 0,4·√(u*·L/f).
pub fn bl_depth(u10: f64, z0: f64, f_cor: f64, cls: usize) -> f64 {
    let us = KAPPA * u10.max(U10_MIN) / (10.0 / z0).ln();
    let mut h = NEUTRAL_BL_K * us / f_cor;
    if cls > D {
        h = h.min(0.4 * (us / obukhov_inv(cls, z0) / f_cor).sqrt());
    }
    h
}

/// Высота насыщения профиля, м.
pub fn z_sat(cfg: &WindProfileCfg, u10: f64, z0: f64, f_cor: f64, cls: usize) -> f64 {
    cfg.z_sat_frac * bl_depth(u10, z0, f_cor, cls)
}

/// U(z_sat)/U10 = (z_sat/10)^α.
pub fn max_profile(
    cfg: &WindProfileCfg,
    alpha_v: f64,
    u10: f64,
    z0: f64,
    f_cor: f64,
    cls: usize,
) -> f64 {
    (z_sat(cfg, u10, z0, f_cor, cls) / 10.0).powf(alpha_v)
}

/// α, класс, z_sat и max_profile случая решателя (`WindProfile.apply_to_case`): ветер меню,
/// эффективный z0 области, солнце в момент `hour`, облачность неба.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaseProfile {
    pub sun_elev_deg: f64,
    pub class: usize,
    pub alpha: f64,
    pub z_sat: f64,
    pub max_profile: f64,
}

pub fn apply_to_case(
    cfg: &WindProfileCfg,
    u10_menu: f64,
    z0: f64,
    f_cor: f64,
    sun_elev_deg: f64,
    cover: f64,
) -> CaseProfile {
    let class = stability_class(u10_menu, sun_elev_deg, cover);
    let a = alpha(cfg, u10_menu, sun_elev_deg, cover);
    CaseProfile {
        sun_elev_deg,
        class,
        alpha: a,
        z_sat: z_sat(cfg, u10_menu, z0, f_cor, class),
        max_profile: max_profile(cfg, a, u10_menu, z0, f_cor, class),
    }
}
