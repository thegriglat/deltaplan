//! Механизм F (свободная конвекция): подобие слоя перемешивания [LWP80, LS80] — σ_w/w*, ⟨w′³⟩,
//! асимметрия, доля и скорость восходящих; скорость слоя перемешивания и баланс θ′ вдоль ветра.
//! Эталон — `AirPhase.{updraft, convection_profile}`, `AirPhaseCpu.{uml, theta}`.
//!
//! Все циклы — плоские массивы SoA, обход подряд; rayon по строкам и столбцам, каждое число
//! считается одним потоком (порядок сложений не зависит от числа потоков, побитно). Проходы
//! баланса θ′ — два буфера по очереди, без новых выделений в проходе.
use super::calm::mix;
use super::classifier::Classified;
use super::config::PhaseCfg;
use super::mech::{MechFields, mech_at};
use super::prepare::Prepared;
use rayon::prelude::*;

/// Подобие слоя перемешивания на доле высоты `z/z_i` (только для (0, 1)).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Updraft {
    /// σ_w/w*.
    pub sigma_w: f64,
    /// ⟨w′³⟩/w*³.
    pub w3: f64,
    /// Асимметрия S = ⟨w′³⟩/σ_w³.
    pub skew: f64,
    /// Доля площади восходящих `½(1 − S/√(S² + 4))` (модель потока массы, Randall 1992).
    pub a_up: f64,
    /// Скорость восходящих `w_up/w*`.
    pub w_up: f64,
}

/// `σ_w²/w*² = a·(z/z_i)^(2/3)·(1 − b·z/z_i)²`, `⟨w′³⟩/w*³ = c·(z/z_i)(1 − z/z_i)²` [LWP80].
pub fn updraft(cfg: &PhaseCfg, zr: f64) -> Updraft {
    let f = &cfg.f;
    let sw = (f.sigw_a * zr.powf(2.0 / 3.0) * (1.0 - f.sigw_b * zr).max(0.0).powi(2)).sqrt();
    let w3 = f.w3_a * zr * (1.0 - zr).powi(2);
    let s = w3 / (sw * sw * sw).max(1e-12);
    let au = 0.5 * (1.0 - s / (s * s + 4.0).sqrt());
    Updraft {
        sigma_w: sw,
        w3,
        skew: s,
        a_up: au,
        w_up: sw * ((1.0 - au) / au).sqrt(),
    }
}

/// Профиль подобия на десяти долях `z/z_i` (0,05 … 0,95): `(z/z_i, Updraft)`.
pub fn convection_profile(cfg: &PhaseCfg) -> [(f64, Updraft); 10] {
    std::array::from_fn(|q| {
        let zr = (q as f64 + 0.5) / 10.0;
        (zr, updraft(cfg, zr))
    })
}

/// Скорость слоя перемешивания: средняя `|u_h|` смеси (варианта с нагревом) на первых
/// `uml_levels` высотах линейной теории (`AirPhaseCpu.uml`), не меньше `uml_min_ms`.
pub fn uml(p: &Prepared, w: &Classified, mf: &MechFields) -> Vec<f64> {
    let nu = p.prm.uml_n;
    let mut out = vec![0.0; p.n2];
    out.par_iter_mut().enumerate().for_each(|(c, o)| {
        let hc = p.cols.hc[c];
        let mut s = 0.0;
        for l in 0..nu {
            let m = mech_at(p, mf, c, hc + mf.slab.lev[l]);
            let u = mix(w, p.n2, c, &m);
            s += (u[0] * u[0] + u[1] * u[1]).sqrt();
        }
        *o = (s / nu.max(1) as f64).max(p.prm.uml_min);
    });
    out
}

/// θ′ слоя перемешивания — стационарный баланс вдоль ветра (AP-17 `theta_march`), проходы Якоби
/// `nx + ny` раз (цепочка вверх по ветру выходит из области — точное решение). Переносится
/// теплосодержание `E = θ′·h` (TW-3): `θ′_in = E_up / max(h, h_up)` — растущий слой разбавляет
/// тепло, тонеющий сохраняет θ′; при постоянном `h` — `θ′_in = θ′_up`. `um` — [`uml`].
pub fn theta(p: &Prepared, um: &[f64]) -> Vec<f64> {
    let (nx, ny, n2) = (p.nx, p.ny, p.n2);
    let (ex, ey) = (p.prm.ex, p.prm.ey);
    let tau = p.prm.tau;
    let hb: Vec<f64> = p.cols.hbl.iter().map(|&h| h.max(1.0)).collect();
    let mut fa = vec![0.0; n2];
    let mut src = vec![0.0; n2];
    fa.par_iter_mut()
        .zip(src.par_iter_mut())
        .enumerate()
        .for_each(|(c, (f, s))| {
            let dt = p.prm.dx / um[c];
            *f = (-dt / tau).exp();
            *s = p.cols.hk[c] / hb[c] * tau * (1.0 - *f);
        });
    let mut th = src.clone();
    let mut nw = vec![0.0; n2];
    for _ in 0..nx + ny {
        nw.par_chunks_mut(nx).enumerate().for_each(|(j, row)| {
            for (i, o) in row.iter_mut().enumerate() {
                let c = j * nx + i;
                let fi = i as f64 - ex;
                let fj = j as f64 - ey;
                let mut v = 0.0;
                if fi >= 0.0 && fi <= (nx - 1) as f64 && fj >= 0.0 && fj <= (ny - 1) as f64 {
                    let i0 = (fi.floor() as i64).clamp(0, nx as i64 - 2) as usize;
                    let j0 = (fj.floor() as i64).clamp(0, ny as i64 - 2) as usize;
                    let aa = fi - i0 as f64;
                    let bb = fj - j0 as f64;
                    let q00 = j0 * nx + i0;
                    let (q10, q01, q11) = (q00 + 1, q00 + nx, q00 + nx + 1);
                    let eu = (1.0 - bb) * ((1.0 - aa) * th[q00] * hb[q00] + aa * th[q10] * hb[q10])
                        + bb * ((1.0 - aa) * th[q01] * hb[q01] + aa * th[q11] * hb[q11]);
                    let hu = (1.0 - bb) * ((1.0 - aa) * hb[q00] + aa * hb[q10])
                        + bb * ((1.0 - aa) * hb[q01] + aa * hb[q11]);
                    v = eu / hb[c].max(hu);
                }
                *o = v * fa[c] + src[c];
            }
        });
        std::mem::swap(&mut th, &mut nw);
    }
    th
}
