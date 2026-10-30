//! Поверхностный порыв на 10 м для пыли (RW-8s, W6 v4): `GustDustModel.gust_ms`
//!.
//!
//! `порыв = max(u + σ·(g·dir), 0)`, где `u` — профиль ветра на 10 м над землёй (`WindModel.speed_at(10)`),
//! `σ = √((gust_sigma_frac·u)² + (conv_sigma_k·convective_turbulence_ms)²)`, `g = gust_unit((x, 10, z),
//! t, u, gust_large_k)` (шум порывов `terms::turb::gust`, переносимый ветром `u`), `dir` — куда дует ветер.
//! Константы — секция `atmosphere → gust_dust`. Ветер и `convective_turbulence_ms` берутся из
//! `Terms` на момент вызова; `t` — только фаза шума, любой (в том числе прошлые слоты). Чистая функция
//! `(x, z, t)` при зафиксированных ветре и погоде.
//!
//! Нечисловой вход (`x`, `z` или `t`) даёт 0. «Нет места / не READY — нули» (W6) решает фасад
//! (RW-12z): здесь места нет в аргументах. Отладочный `force_u10` не переносится (решение 2026-10-29).
use super::{
    Terms, named_json,
    turb::gust,
    turb::{GustCfg, GustUnit},
};
use crate::Configs;
use serde_json::Value;

/// Константы секция `atmosphere → gust_dust` (запасные — как в `GustDustModel`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GustDustCfg {
    /// `gust_sigma_frac`: СКО продольной пульсации у земли — доля среднего ветра.
    pub sigma_frac: f64,
    /// `conv_sigma_k`: вклад `convective_turbulence_ms` погоды в СКО.
    pub conv_k: f64,
    /// `gust_large_k`: доля крупных вихрей.
    pub large_k: f64,
}

impl Default for GustDustCfg {
    fn default() -> Self {
        GustDustCfg {
            sigma_frac: 0.25,
            conv_k: 0.5,
            large_k: 0.6,
        }
    }
}

impl GustDustCfg {
    pub fn from_configs(c: &Configs) -> Self {
        let atm = named_json(c, "atmosphere").unwrap_or(Value::Null);
        let d = GustDustCfg::default();
        let g = |k: &str, dv: f64| {
            atm.pointer(&format!("/gust_dust/{k}"))
                .and_then(Value::as_f64)
                .unwrap_or(dv)
        };
        GustDustCfg {
            sigma_frac: g("gust_sigma_frac", d.sigma_frac),
            conv_k: g("conv_sigma_k", d.conv_k),
            large_k: g("gust_large_k", d.large_k),
        }
    }
}

/// Шум порывов мира и константы пыли: строится по конфигам и сиду (нормировка шума — 2048
/// отсчётов), поэтому живёт в `Terms` и создаётся лениво.
pub struct SurfaceGust {
    cfg: GustDustCfg,
    noise: GustUnit,
}

impl SurfaceGust {
    pub fn new(configs: &Configs, seed: u64) -> Self {
        SurfaceGust {
            cfg: GustDustCfg::from_configs(configs),
            noise: GustUnit::new(&GustCfg::from_configs(configs), seed as i64),
        }
    }

    pub fn cfg(&self) -> &GustDustCfg {
        &self.cfg
    }

    /// Порыв, м/с, в `(x, z)` в момент `t` при среднем ветре `u` на 10 м, направлении `dir` (в f32,
    /// как `Vector3` GD) и `convective_turbulence_ms = conv`. Нечисловой вход - 0.
    pub fn gust_ms(&self, x: f32, z: f32, t: f64, u: f64, dir: [f64; 2], conv: f64) -> f32 {
        if !(x.is_finite() && z.is_finite() && t.is_finite() && u.is_finite() && conv.is_finite()) {
            return 0.0;
        }
        let sigma = ((self.cfg.sigma_frac * u).powi(2) + (self.cfg.conv_k * conv).powi(2)).sqrt();
        let g = gust::gust(&self.noise, [x, 10.0, z], t, dir, u, self.cfg.large_k);
        let (dx, dz) = (f64::from(dir[0] as f32), f64::from(dir[1] as f32));
        let v = (u + sigma * (g[0] * dx + g[2] * dz)).max(0.0);
        if v.is_finite() { v as f32 } else { 0.0 }
    }
}

/// Порыв на 10 м в точках `xz` (x, z мира) в моменты `t` (свой на точку); `out[i]` - м/с. Длины - по
/// минимуму из трёх, остальное в `out` не трогается.
pub fn surface_gust_many(terms: &Terms, xz: &[[f32; 2]], t: &[f64], out: &mut [f32]) {
    let sg = terms.surface_gust();
    let u = terms.wind.speed_at(10.0);
    let dir = terms.wind.dir();
    let conv = terms.weather.f64_or("convective_turbulence_ms", 0.0);
    gust_batch(sg, (u, dir, conv), xz, t, out);
}

#[cfg_attr(
    target_arch = "x86_64",
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
fn gust_batch(
    sg: &SurfaceGust,
    (u, dir, conv): (f64, [f64; 2], f64),
    xz: &[[f32; 2]],
    t: &[f64],
    out: &mut [f32],
) {
    for ((o, p), &ti) in out.iter_mut().zip(xz).zip(t) {
        *o = sg.gust_ms(p[0], p[1], ti, u, dir, conv);
    }
}
