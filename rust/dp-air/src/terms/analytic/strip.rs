//! Аналитика в полосе края поля: доля
//! `(1 − a)` аналитики поверх поля. Формулы весов и сложения — буквально GD (формулы, не физика).
//!
//! Отличия от ветки без поля: ослабления ветра нет вне `(1 − a)`; подветренное опускание, рывки
//! и ротор — тоже со своим весом `(1 − a)`, рывки и ротор — без множителя нагрева земли
//! (`_lee_heat_factor` в этой ветке в GD не применяется).
use super::{Pt, lee::LeeCfg};
use crate::terms::AnalyticMean;

/// Среднее аналитики в полосе края `0 < a < 1`.
pub fn mean(p: &Pt, a: f64) -> AnalyticMean {
    let cfg: &LeeCfg = &p.st.cfg.lee;
    let (u, y) = (p.u, p.pos[1]);
    let mut lee_a = 0.0;
    let mut relief = -1.0;
    let mut w_ridge = 0.0;
    if u > 0.0 {
        let depth = p.gs.shadow - f64::from(y);
        if depth > -cfg.shear {
            relief =
                p.gf.relief_at(p.place, f64::from(p.pos[0]), f64::from(p.pos[2]));
            lee_a = cfg.strength(depth, relief);
        }
        w_ridge = p.ridge_lift() * (1.0 - lee_a);
    }
    let danger = if lee_a > 0.0 { p.danger() } else { 0.0 };
    let mut h = u * (1.0 - a) * (1.0 - lee_a * cfg.wind_red);
    let mut w = 0.0;
    if lee_a > 0.0 {
        let k = cfg.sink + (cfg.danger_sink - cfg.sink) * danger;
        w -= (1.0 - a) * k * u * lee_a;
    }
    let hard_a = (1.0 - a) * u * lee_a * danger;
    if hard_a > 0.0 {
        // рывки вниз в пятнах шума и ротор у земли — как в аналитике
        if hard_a > 1.0e-3 {
            w -= cfg.burst * hard_a * p.burst_g();
        }
        h -= cfg.reverse * hard_a * (-p.agl / (cfg.rotor_h * relief).max(1.0)).exp();
    }
    AnalyticMean {
        h,
        w_ridge: (1.0 - a) * w_ridge,
        w_lee: w,
        lee: lee_a,
        danger,
        relief,
    }
}
