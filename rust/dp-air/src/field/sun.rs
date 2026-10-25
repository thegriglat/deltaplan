//! Положение солнца: перенос `SunClock.solar_position` (формулы NOAA, ряды Спенсера) и
//! календарных функций `SunClock`. Градусы, часы места, невисокосный год.
use std::f64::consts::{PI, TAU};

const DAYS: [i64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

/// Дней в месяце (невисокосный год); месяц зажимается в 1..12.
pub fn days_in_month(m: i64) -> i64 {
    DAYS[(m.clamp(1, 12) - 1) as usize]
}

/// Номер дня в году, 1..365.
pub fn day_of_year(m: i64, d: i64) -> i64 {
    d + (1..m.clamp(1, 12)).map(days_in_month).sum::<i64>()
}

/// `fposmod` движка: остаток с знаком делителя.
pub fn fposmod(x: f64, y: f64) -> f64 {
    let mut v = x % y;
    if (v < 0.0 && y > 0.0) || (v > 0.0 && y < 0.0) {
        v += y;
    }
    v + 0.0
}

/// Линейная интерполяция движка `lerpf`.
#[inline]
pub fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

/// Азимут (от севера по часовой) и высота солнца, градусы. `clock_h` — местное солнечное время,
/// если `utc_offset_h` — NaN, иначе поясное время со смещением от UTC.
pub fn solar_position(
    lat_deg: f64,
    lon_deg: f64,
    doy: i64,
    clock_h: f64,
    utc_offset_h: f64,
) -> (f64, f64) {
    let g = TAU / 365.0 * (doy as f64 - 1.0 + (clock_h - 12.0) / 24.0);
    let decl = 0.006918 - 0.399912 * g.cos() + 0.070257 * g.sin() - 0.006758 * (2.0 * g).cos()
        + 0.000907 * (2.0 * g).sin()
        - 0.002697 * (3.0 * g).cos()
        + 0.00148 * (3.0 * g).sin();
    let mut solar_h = clock_h;
    if !utc_offset_h.is_nan() {
        let eot = 229.18
            * (0.000075 + 0.001868 * g.cos()
                - 0.032077 * g.sin()
                - 0.014615 * (2.0 * g).cos()
                - 0.040849 * (2.0 * g).sin());
        solar_h = clock_h + (4.0 * lon_deg - 60.0 * utc_offset_h + eot) / 60.0;
    }
    let ha = (15.0 * (solar_h - 12.0)).to_radians();
    let lat = lat_deg.to_radians();
    let sin_el = lat.sin() * decl.sin() + lat.cos() * decl.cos() * ha.cos();
    let el = sin_el.clamp(-1.0, 1.0).asin();
    let az = ha
        .sin()
        .atan2(ha.cos() * lat.sin() - decl.tan() * lat.cos())
        + PI;
    (fposmod(az.to_degrees(), 360.0), el.to_degrees())
}

/// Единичный вектор НА солнце: север −Z, восток +X (`TerrainGeo.sun_direction`).
pub fn sun_direction(azimuth_deg: f64, elevation_deg: f64) -> [f64; 3] {
    let az = azimuth_deg.to_radians();
    let el = elevation_deg.to_radians();
    let v = [az.sin() * el.cos(), el.sin(), -az.cos() * el.cos()];
    let n = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    [v[0] / n, v[1] / n, v[2] / n]
}
