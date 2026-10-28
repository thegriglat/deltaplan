//! Разложение W7: имена слагаемых и запись вкладов внутри `sum` (запись не меняет счёта).
use crate::Decomposition;

/// Имена слагаемых `Atmosphere.T_NAMES`, порядок постоянный.
pub const NAMES: [&str; 9] = [
    "field", "analytic", "ridge", "thermal", "storm", "wave", "cloud", "turb", "gust",
];
pub const T_FIELD: usize = 0;
pub const T_ANALYTIC: usize = 1;
pub const T_RIDGE: usize = 2;
pub const T_THERMAL: usize = 3;
pub const T_STORM: usize = 4;
pub const T_WAVE: usize = 5;
pub const T_CLOUD: usize = 6;
pub const T_TURB: usize = 7;
pub const T_GUST: usize = 8;

/// Вклады слагаемых в точке: скорость (со своими весами, в т. ч. полосы края) и σ справочно
/// (`turb` — σ_u поля, `gust` — σ аналитики).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rec {
    pub vel: [[f64; 3]; 9],
    pub sigma: [f64; 9],
}

impl Rec {
    pub fn add(&mut self, i: usize, v: [f64; 3]) {
        for (a, b) in self.vel[i].iter_mut().zip(v) {
            *a += b;
        }
    }

    /// Разложение с итогом `total` (результат той же `sum`).
    pub fn into_decomposition(self, total: [f32; 4]) -> Decomposition {
        Decomposition {
            names: NAMES.iter().map(|s| (*s).to_string()).collect(),
            vel: self
                .vel
                .iter()
                .map(|v| [v[0] as f32, v[1] as f32, v[2] as f32])
                .collect(),
            sigma: self.sigma.iter().map(|s| *s as f32).collect(),
            total,
        }
    }
}

/// Нулевое разложение (воздух не собран, точка не конечна): имена есть, вклады нули.
pub fn empty() -> Decomposition {
    Rec::default().into_decomposition([0.0; 4])
}
