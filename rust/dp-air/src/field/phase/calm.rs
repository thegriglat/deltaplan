//! Механизм H (штиль) и смесь механических полей по весам. Штиль в механике — то же потенциальное
//! поле, что у D (слои Лапласа, [`super::layers`]): в `AirPhaseCpu.mix` веса D и H складываются
//! и берут поле D; случайные отклонения штиля даёт сама карта весов (P15, `w_h`), а не отдельное
//! поле. Здесь — нормированная смесь `mix`.
use super::classifier::Classified;
use super::prepare::{PH_A, PH_B, PH_C, PH_D, PH_H};

/// Нормированная смесь механического поля (A, C → A; D, H → D; B → B; F, G — отдельно) по весам
/// столбца `c`; `m` — 10 чисел [`super::mech::mech_at`]. Результат — f32 (`Vector3` GDScript).
#[inline]
pub fn mix(w: &Classified, n2: usize, c: usize, m: &[f64; 10]) -> [f64; 3] {
    let wa = w.weights[PH_A * n2 + c] + w.weights[PH_C * n2 + c];
    let wd = w.weights[PH_D * n2 + c] + w.weights[PH_H * n2 + c];
    let wb = w.weights[PH_B * n2 + c];
    let sm = (wa + wb + wd).max(1e-12);
    let f = |a: f64, b: f64, d: f64| f64::from(((wa * a + wb * b + wd * d) / sm) as f32);
    [
        f(m[0], m[4], m[7]),
        f(m[1], m[5], m[8]),
        f(m[2], m[6], m[9]),
    ]
}
