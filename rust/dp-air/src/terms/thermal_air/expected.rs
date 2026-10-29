//! Форма пузыря (как `ThermalField.sample`): профиль потока ядра по ξ, средний поток по глубине
//! столба, доля жизни. Нужна и `build` (плотность, сила), и `expected_net`/`expected_up`.
use super::{AirThermalsCfg, CORE_FLUX, NQ, SM_STEP, gclamp, gmax, smoothstep};

/// Профиль потока ядра `q(ξ)`, таблица среднего потока по глубине столба и доля жизни.
#[derive(Clone, Debug)]
pub struct Shape {
    /// `q` по ξ = 0..1, `NQ` точек (хранится `f32`).
    q: Vec<f32>,
    /// Среднее `q` по ξ (трапеции).
    pub q_mean: f64,
    /// Средний по столбу поток ядра на 1 м/с пика и R² = 1 по глубине `n·25 м`, `n = 0..240`.
    sm: Vec<f32>,
    /// `⟨огибающая × доля циклов⟩`.
    pub life_mean: f64,
    /// Доля времени, когда термик источника жив.
    pub alive_frac: f64,
    /// `e⁻¹·π·q_mean`.
    pub shape_area: f64,
}

fn q_at(xi: f64, d: f64, cfg: &AirThermalsCfg) -> f64 {
    let rf = gmax(
        cfg.radius_min_factor,
        xi.powf(1.0 / 3.0) * (1.0 - 0.25 * xi) / 0.75,
    );
    let dh = xi * d;
    let vert = if dh > 0.0 {
        (dh / cfg.ground_ramp_m).powf(1.0 / 3.0).min(1.0)
    } else {
        0.0
    };
    let tp = smoothstep(0.0, cfg.top_taper_m, d - dh);
    rf * rf * vert * tp
}

fn shape_mean_exact(d: f64, cfg: &AirThermalsCfg) -> f64 {
    let mut s = 0.0f64;
    for n in 0..NQ {
        let xi = n as f64 / (NQ - 1) as f64;
        s += q_at(xi, d, cfg) * if n == 0 || n == NQ - 1 { 0.5 } else { 1.0 };
    }
    s / (NQ - 1) as f64
}

impl Shape {
    pub fn new(cfg: &AirThermalsCfg) -> Shape {
        let (g, m, d, gap) = (cfg.grow_s, cfg.mature_s, cfg.decay_s, cfg.gap_s);
        let life_mean = (0.5 * g + m + 0.5 * d) / (g + m + d + gap) * cfg.duty;
        let alive_frac = (g + m + d) / (g + m + d + gap) * cfg.duty;
        let d0 = 1000.0;
        let mut q = vec![0f32; NQ];
        let mut s = 0.0f64;
        for (n, qn) in q.iter_mut().enumerate() {
            let xi = n as f64 / (NQ - 1) as f64;
            *qn = q_at(xi, d0, cfg) as f32;
            s += *qn as f64 * if n == 0 || n == NQ - 1 { 0.5 } else { 1.0 };
        }
        let q_mean = gmax(s / (NQ - 1) as f64, 1.0e-6);
        let sm = (0..241)
            .map(|n| shape_mean_exact(gmax(n as f64 * SM_STEP, 1.0), cfg) as f32)
            .collect();
        Shape {
            q,
            q_mean,
            sm,
            life_mean,
            alive_frac,
            shape_area: CORE_FLUX * std::f64::consts::PI * q_mean,
        }
    }

    /// Средний по столбу глубины `d` поток ядра на 1 м/с пика и R² = 1 (таблица, шаг 25 м).
    pub fn mean(&self, d: f64) -> f64 {
        let fd = gclamp(d / SM_STEP, 0.0, self.sm.len() as f64 - 1.001);
        let k = fd as usize;
        let (a, b) = (self.sm[k] as f64, self.sm[k + 1] as f64);
        a + (b - a) * (fd - k as f64)
    }

    /// `q(ξ)` линейно по таблице, ξ в (0, 1).
    pub fn q_at_profile(&self, xi: f64) -> f64 {
        let fq = xi * (NQ - 1) as f64;
        let k = fq as usize;
        let (a, b) = (self.q[k] as f64, self.q[(k + 1).min(NQ - 1)] as f64);
        a + (b - a) * (fq - k as f64)
    }
}
