//! Поля механизмов A, B, D (и H через D) в точке: подготовка ([`MechFields`]) и значение
//! ([`mech_at`], `AirPhaseCpu.mech`). F, G и сборка по клеткам — RW-6m.
use super::bubble::wind_b;
use super::layers::{Laplace, laplace, wind_d};
use super::linear::{Modes, Slab, modes, synth, wind_a};
use super::prepare::Prepared;

/// То, что считается по случаю один раз: моды A, слой возмущений A, слои Лапласа D.
#[derive(Clone, Debug)]
pub struct MechFields {
    pub modes: Modes,
    pub slab: Slab,
    pub lap: Laplace,
}

impl MechFields {
    pub fn new(p: &Prepared) -> MechFields {
        let m = modes(p);
        let slab = synth(p, &m);
        MechFields {
            modes: m,
            slab,
            lap: laplace(p),
        }
    }
}

/// Поля механизмов в точке (столбец `c`, высота `zmsl` над морем): A `(u, v, w)`, η, B `(u, v, w)`,
/// D `(u, v, w)` — 10 чисел: `[uA, vA, wA, η, uB, vB, wB, uD, vD, wD]`. Где B или D не действуют —
/// поле A (как в эталоне).
pub fn mech_at(p: &Prepared, f: &MechFields, c: usize, zmsl: f64) -> [f64; 10] {
    let a = wind_a(p, &f.slab, c, zmsl);
    let b = wind_b(p, &f.slab, c, zmsl).unwrap_or([a[0], a[1], a[2]]);
    let d = wind_d(p, &f.lap, c, zmsl).unwrap_or([a[0], a[1], a[2]]);
    [a[0], a[1], a[2], a[3], b[0], b[1], b[2], d[0], d[1], d[2]]
}
