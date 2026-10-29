//! Подветренная зона аналитики (`atmosphere.gd`: `_lee_danger` 1215, `_lee_burst_g` 1224,
//! `_lee_heat_factor` 1232, `_lee_flow` 1254, зона в `air_velocity_at` 934–944 и в
//! `_air_velocity_field` 1083–1090).
//!
//! Зона — ниже линии тени от гребня против ветра (и в слое сдвига над ней), сила зоны `lee` =
//! глубина × превышение гребня. Внутри: опускание, рывки сверху (пятна детерминированного шума),
//! ротор — обратный поток у земли; опасность растёт с ветром прогноза (smoothstep).
use super::noise::GustNoise;
use crate::field::case_prepare::{G, RHO_CP, THETA0};
use crate::field::wind_field::ZI_MIN;

/// `lee.*` и `turbulence.scale_m` (для масштаба пятен рывков).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LeeCfg {
    pub depth: f64,
    pub relief: f64,
    pub sink: f64,
    pub turb: f64,
    pub wind_red: f64,
    pub shear: f64,
    pub danger_min: f64,
    pub danger_full: f64,
    pub danger_sink: f64,
    pub danger_turb: f64,
    pub burst: f64,
    /// `turbulence.scale_m / lee.burst_scale_m`.
    pub burst_k: f64,
    pub burst_thr: f64,
    pub burst_width: f64,
    pub reverse: f64,
    pub rotor_h: f64,
    pub rotor_max: f64,
    pub heat_full: f64,
    pub heat_wstar_k: f64,
}

impl Default for LeeCfg {
    fn default() -> Self {
        LeeCfg {
            depth: 120.0,
            relief: 150.0,
            sink: 0.25,
            turb: 0.5,
            wind_red: 0.6,
            shear: 40.0,
            danger_min: 2.0,
            danger_full: 5.0,
            danger_sink: 0.25,
            danger_turb: 0.5,
            burst: 1.0,
            burst_k: 0.375,
            burst_thr: 0.8,
            burst_width: 1.0,
            reverse: 0.9,
            rotor_h: 0.4,
            rotor_max: 7.0,
            heat_full: 0.0,
            heat_wstar_k: 0.6,
        }
    }
}

/// `smoothstep(from, to, x)` Godot.
pub fn smoothstep(from: f64, to: f64, x: f64) -> f64 {
    if (from - to).abs() < f64::EPSILON {
        return if x < from { 0.0 } else { 1.0 };
    }
    let t = ((x - from) / (to - from)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

impl LeeCfg {
    /// Опасность зоны 0..1 от ветра прогноза `u_ref` (на старте, с поправкой на высоту).
    pub fn danger(&self, u_ref: f64) -> f64 {
        smoothstep(self.danger_min, self.danger_full, u_ref)
    }

    /// Сила зоны 0..1 по глубине под линией тени (`depth = тень − y`) и превышению гребня.
    /// Вне слоя сдвига (`depth ≤ −shear`) — `None` (превышение не считают).
    pub fn strength(&self, depth: f64, relief: f64) -> f64 {
        ((depth + self.shear) / (self.depth + self.shear)).clamp(0.0, 1.0)
            * (relief / self.relief).clamp(0.0, 1.0)
    }

    /// Ослабление ротора нагревом земли 0..1 (1 — нет нагрева): `w*` из конвективной болтанки
    /// погоды, `H = w*³·ρc_p/(g/θ0·z_i)`, `z_i` — кромка не ниже `ZI_MIN` (AP-10).
    pub fn heat_factor(&self, conv_amp: f64, cloudbase_agl: f64) -> f64 {
        if self.heat_full <= 0.0 {
            return 1.0;
        }
        (1.0 - self.heat_wm2(conv_amp, cloudbase_agl) / self.heat_full).clamp(0.0, 1.0)
    }

    /// Поток тепла дня, Вт/м² (`lee_heat_wm2`).
    pub fn heat_wm2(&self, conv_amp: f64, cloudbase_agl: f64) -> f64 {
        let ws = conv_amp / self.heat_wstar_k.max(0.05);
        let zi = cloudbase_agl.max(ZI_MIN);
        ws.powi(3) * RHO_CP / (G / THETA0 * zi)
    }

    /// Пятно рывка 0..1: `clamp((n − порог)/ширина)`, шум переносится ветром `u`.
    pub fn burst_g(&self, noise: &GustNoise, pos: [f32; 3], t: f64, dir: [f64; 2], u: f64) -> f64 {
        let k = self.burst_k as f32;
        let p = [pos[0] * k, pos[1] * k, pos[2] * k];
        let nb = noise.gust_unit(p, t, dir, u * self.burst_k, 0.0)[0];
        ((nb - self.burst_thr) / self.burst_width).clamp(0.0, 1.0)
    }
}

/// Подветренный поток без поля: `(добавка к горизонтали вдоль ветра, вертикаль)`, м/с.
/// `heat` — `heat_factor` (в ветке полосы края не применяется).
#[allow(clippy::too_many_arguments)]
pub fn flow(
    cfg: &LeeCfg,
    noise: &GustNoise,
    pos: [f32; 3],
    t: f64,
    dir: [f64; 2],
    agl: f64,
    u: f64,
    lee: f64,
    danger: f64,
    relief: f64,
    heat: f64,
) -> (f64, f64) {
    let lerp = |a: f64, b: f64, k: f64| a + (b - a) * k;
    let mut w = -lerp(cfg.sink, cfg.danger_sink, danger) * u * lee;
    let hard = lee * danger * heat;
    if hard < 1.0e-3 {
        return (0.0, w);
    }
    w -= cfg.burst * u * hard * cfg.burst_g(noise, pos, t, dir, u);
    let core = hard * (-agl / (cfg.rotor_h * relief).max(1.0)).exp();
    (-cfg.reverse * u * core, w)
}
