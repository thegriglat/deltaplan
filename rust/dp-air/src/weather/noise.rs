//! Точка росы дня (`td_day`) и детерминированное N(0, 1) (`td_noise`).
use serde_json::Value;

use super::climate::{ClimatePlace, PlaceCtx};
use super::tables::{num, nums};
use crate::field::weather_core::{WeatherModelCfg, season_index};

const GOLDEN: i64 = -7046029254386353131; // 0x9E3779B97F4A7C15
const M1: i64 = -4658895280553007687; // 0xBF58476D1CE4E5B9
const M2: i64 = -7723592293110705685; // 0x94D049BB133111EB

/// Шаг splitmix64 (`state += γ`, затем перемешивание) на `i64` эталона: умножение с переполнением, сдвиги арифметические с маской
/// (как логические).
pub fn splitmix64(x: i64) -> i64 {
    let mut x = x.wrapping_add(GOLDEN);
    x = (x ^ ((x >> 30) & 0x3_FFFF_FFFF)).wrapping_mul(M1);
    x = (x ^ ((x >> 27) & 0x1F_FFFF_FFFF)).wrapping_mul(M2);
    x ^ ((x >> 31) & 0x1_FFFF_FFFF)
}

/// Детерминированное N(0, 1) от (месяц, день, `round(lat·100)`, `round(lon·100)`): splitmix64 ->
/// Бокс — Мюллер (`WeatherModel.td_noise`).
pub fn td_noise(month: i64, day: i64, lat: f64, lon: f64) -> f64 {
    let mut h = GOLDEN;
    for v in [
        month,
        day,
        (lat * 100.0).round() as i64,
        (lon * 100.0).round() as i64,
    ] {
        h = splitmix64(h ^ v.wrapping_add(0x632B_E59B_D9B4_E019));
    }
    let h2 = splitmix64(h ^ 0x2545_F491_4F6C_DD1D);
    let u1 = (((h >> 11) & 0x1F_FFFF_FFFF_FFFF) as f64 + 0.5) / 9007199254740992.0;
    let u2 = ((h2 >> 11) & 0x1F_FFFF_FFFF_FFFF) as f64 / 9007199254740992.0;
    (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos()
}

/// Индекс пояса |φ|: первая верхняя граница, не меньшая |φ| (выше — последний).
pub fn band_index(lat: f64, bounds: &[f64]) -> usize {
    let a = lat.abs();
    bounds
        .iter()
        .position(|&b| a <= b)
        .unwrap_or(bounds.len().saturating_sub(1))
}

fn cell_of(v: Option<&Value>, b: usize, s: usize) -> f64 {
    v.and_then(|t| t.get(b))
        .map(|row| nums(Some(row)))
        .and_then(|r| r.get(s).copied())
        .unwrap_or(0.0)
}

/// Точка росы дня (HH7): `Td = Td_климат + μ_sky·σ + β·(T_max − Tx_климат) + r·ρ·σ`, до зажима
/// `Td ≤ T` (его ставит `derive`). `t_max` и `sky` — из прогноза.
pub fn td_day(
    t_max: f64,
    sky: &str,
    cp: &ClimatePlace,
    ctx: &PlaceCtx,
    cfg: &WeatherModelCfg,
) -> f64 {
    let c = &cfg.raw;
    let tdc = c.get("td_day");
    let skies = tdc.and_then(|t| t.get("sky"));
    let sk = skies
        .and_then(|s| s.get(sky))
        .or_else(|| skies.and_then(|s| s.get("clear")))
        .filter(|v| v.as_object().is_some_and(|o| !o.is_empty()));
    let bounds = tdc
        .and_then(|t| t.get("bands_abs_lat"))
        .map_or_else(|| vec![20.0, 40.0, 60.0, 75.0], |b| nums(Some(b)));
    let b = band_index(ctx.lat, &bounds);
    let s = season_index(ctx.month.clamp(1, 12), ctx.lat);
    let (sd, td) = (cp.td_sd_k, cp.td_c);
    let Some(sk) = sk else {
        return td;
    };
    let mu = cell_of(sk.get("mu_sigma"), b, s);
    let beta = cell_of(sk.get("beta"), b, s);
    let rho = cell_of(sk.get("res_ratio"), b, s);
    let clamp = num(c, &["climate", "r_clamp"], 3.0);
    let r = td_noise(ctx.month.clamp(1, 12), ctx.day, ctx.lat, ctx.lon).clamp(-clamp, clamp);
    td + mu * sd + beta * (t_max - cp.tx_c) + r * rho * sd
}
