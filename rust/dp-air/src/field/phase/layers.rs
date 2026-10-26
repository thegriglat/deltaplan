//! Механизм D: потенциальное обтекание рельефа в слоях `z_L` ниже разделяющей линии тока `H_c`
//! (AP-17 `layer_potential`): уравнение Лапласа для потенциала в области воздуха слоя
//! (клетки с `h_c ≤ z_L`), красно-чёрная верхняя релаксация (SOR) `sor_iters` раз с ω =
//! `sor_omega`, затем скорости в долях набегающей. Эталон — `AirPhaseCpu.{laplace, _face_grad}`,
//! `AirPhaseCpu.mech` (r[7..10]).
//!
//! Красно-чёрный порядок (как в GDScript): внутри цвета клетки не зависят друг от друга, поэтому
//! результат не зависит от порядка обхода и числа потоков. Слои независимы — параллельны.
use super::linear::u_prof;
use super::prepare::{Prepared, r32};
use rayon::prelude::*;

/// Поля слоёв Лапласа: `[(l·3 + q)·n² + c]`, `q`: 0 — φ, 1 — gx, 2 — gy (доли набегающей).
#[derive(Clone, Debug)]
pub struct Laplace {
    pub n2: usize,
    pub nl: usize,
    /// Высоты слоёв, как слоты `prm` GDScript (f32).
    pub zl: Vec<f64>,
    pub data: Vec<f64>,
}

impl Laplace {
    pub fn plane(&self, l: usize, q: usize) -> &[f64] {
        let o = (l * 3 + q) * self.n2;
        &self.data[o..o + self.n2]
    }
}

/// Скорость клетки по граням: среднее двух граней; грани к стенке — 0; край области — `e`.
/// Результат — f32 (`Vector2` GDScript).
#[allow(clippy::too_many_arguments)]
#[inline]
fn face_grad(
    phi: &[f64],
    fl: &[bool],
    nx: usize,
    ny: usize,
    i: usize,
    j: usize,
    ex: f64,
    ey: f64,
) -> (f64, f64) {
    let c = j * nx + i;
    if !fl[c] {
        return (0.0, 0.0);
    }
    let fxl = if i == 0 {
        ex
    } else if fl[c - 1] {
        phi[c] - phi[c - 1]
    } else {
        0.0
    };
    let fxr = if i == nx - 1 {
        ex
    } else if fl[c + 1] {
        phi[c + 1] - phi[c]
    } else {
        0.0
    };
    let fyl = if j == 0 {
        ey
    } else if fl[c - nx] {
        phi[c] - phi[c - nx]
    } else {
        0.0
    };
    let fyr = if j == ny - 1 {
        ey
    } else if fl[c + nx] {
        phi[c + nx] - phi[c]
    } else {
        0.0
    };
    (r32(0.5 * (fxl + fxr)), r32(0.5 * (fyl + fyr)))
}

/// Слои Лапласа (`AirPhaseCpu.laplace`). `nl = 0` (нет сильного D) — пустой результат.
pub fn laplace(p: &Prepared) -> Laplace {
    let (nx, ny, n2) = (p.nx, p.ny, p.n2);
    let nl = p.zl.len();
    let zl: Vec<f64> = p.zl.iter().map(|&z| r32(z)).collect();
    let mut data = vec![0.0; nl.max(1) * 3 * n2];
    if nl > 0 {
        let (ex, ey, om) = (p.prm.ex, p.prm.ey, p.prm.sor_omega);
        let iters = p.cfg.d.sor_iters;
        let hc = &p.cols.hc;
        data.par_chunks_mut(3 * n2)
            .zip(zl.par_iter())
            .for_each(|(o, &z)| {
                let (phi, g) = o.split_at_mut(n2);
                let fl: Vec<bool> = hc.iter().map(|&h| h <= z).collect();
                for (c, v) in phi.iter_mut().enumerate() {
                    *v = ex * ((c % nx) as f64 + 0.5) + ey * ((c / nx) as f64 + 0.5);
                }
                for _ in 0..iters {
                    for par in 0..2 {
                        for j in 1..ny - 1 {
                            for i in 1..nx - 1 {
                                if (i + j) % 2 != par {
                                    continue;
                                }
                                let c = j * nx + i;
                                if !fl[c] {
                                    continue;
                                }
                                let mut s = 0.0;
                                let mut cnt = 0;
                                for nb in [c - 1, c + 1, c - nx, c + nx] {
                                    if fl[nb] {
                                        s += phi[nb];
                                        cnt += 1;
                                    }
                                }
                                if cnt > 0 {
                                    phi[c] = (1.0 - om) * phi[c] + om * s / f64::from(cnt);
                                }
                            }
                        }
                    }
                }
                let (gx, gy) = g.split_at_mut(n2);
                for j in 0..ny {
                    for i in 0..nx {
                        let (a, b) = face_grad(phi, &fl, nx, ny, i, j, ex, ey);
                        gx[j * nx + i] = a;
                        gy[j * nx + i] = b;
                    }
                }
            });
    }
    Laplace { n2, nl, zl, data }
}

/// Поле D `(u, v, w)` в столбце `c` на высоте `zmsl`, если `zmsl < H_c` и слои есть; иначе `None`
/// (поле D = поле A). Скорость — линейно по высоте между слоями × профиль притока на `z − h_c`.
pub fn wind_d(p: &Prepared, lap: &Laplace, c: usize, zmsl: f64) -> Option<[f64; 3]> {
    let nl = lap.nl;
    if !(nl > 0 && zmsl < p.prm.hcd) {
        return None;
    }
    let zagl = zmsl - p.cols.hc[c];
    let zl = &lap.zl;
    let mut q = -1i64;
    for (l, &z) in zl.iter().enumerate() {
        if z < zmsl {
            q = l as i64;
        }
    }
    let q = q.clamp(0, nl as i64 - 1) as usize;
    let q2 = (q + 1).min(nl - 1);
    let den = (zl[q2] - zl[q]).max(1e-6);
    let tq = ((zmsl - zl[q]) / den).clamp(0.0, 1.0);
    let n2 = lap.n2;
    let g = |l: usize, k: usize| lap.data[(l * 3 + k) * n2 + c];
    let gx = (1.0 - tq) * g(q, 1) + tq * g(q2, 1);
    let gy = (1.0 - tq) * g(q, 2) + tq * g(q2, 2);
    let ua = u_prof(p, zagl);
    Some([gx * ua, gy * ua, 0.0])
}
