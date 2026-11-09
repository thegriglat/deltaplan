//! Форма пузыря: профиль потока вверх шаблона по ξ (`bubble_q`, TB1 v5 `between_q`), доля жизни. Нужна и `build`
//! (плотность, сила), и `expected_net`/`expected_up`.
use super::{AirThermalsCfg, CORE_FLUX};
use crate::terms::thermal::bubble_q;

/// Профиль потока вверх шаблона `q(ξ)` и доли жизни.
#[derive(Clone, Debug)]
pub struct Shape {
    /// Среднее `q` по ξ (трапеции по узлам таблицы; 1 с точностью таблицы).
    pub q_mean: f64,
    /// `⟨огибающая × доля циклов⟩`.
    pub life_mean: f64,
    /// Доля времени, когда термик источника жив.
    pub alive_frac: f64,
    /// Доля времени, когда термик источника жив, если бы `duty` было 1.
    pub cycle_frac: f64,
    /// `e⁻¹·π·q_mean`.
    pub shape_area: f64,
}

impl Shape {
    pub fn new(cfg: &AirThermalsCfg) -> Shape {
        let (g, m, d, gap) = (cfg.grow_s, cfg.mature_s, cfg.decay_s, cfg.gap_s);
        let life_mean = (0.5 * g + m + 0.5 * d) / (g + m + d + gap) * cfg.duty;
        let cycle_frac = (g + m + d) / (g + m + d + gap);
        let alive_frac = cycle_frac * cfg.duty;
        let q_mean = bubble_q::mean();
        Shape {
            q_mean,
            life_mean,
            alive_frac,
            cycle_frac,
            shape_area: CORE_FLUX * std::f64::consts::PI * q_mean,
        }
    }

    /// `q(ξ)` линейно между узлами таблицы шаблона ([`bubble_q::between_q`]), ξ в (0, 1).
    pub fn q_at_profile(&self, xi: f64) -> f64 {
        bubble_q::between_q(xi)
    }
}
