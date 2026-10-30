//! Классификатор механизмов (P10 v3, P15): сырые веса A, B, C, D, F, G, H по столбцам, сглаживание
//! гауссом и нормировка Σ = 1, маски заморозки колонн для Пикара. Эталон — `AirPhaseCpu.{classify,
//! smooth, finalize}` и `air_phase.glsl:{classify, smooth, final}`.
//!
//! Два варианта: [`Variant::Mech`] (решение без нагрева: F и G нет; для `w_mech`) и [`Variant::Heat`]
//! (с нагревом, если он есть, и со стоком G, если он включён). Маска заморозки — формат W11:
//! `ny·nx` без ореола, строка по `y` сетки, `1` — колонна отдана механизму (вес ≥ `freeze_w`).
//!
//! Все циклы — по столбцам, плоские массивы SoA; параллельность rayon по строкам, каждый результат
//! считается одним потоком, порядок сложений не зависит от числа потоков (побитно).
use super::prepare::{
    K, PH_A, PH_B, PH_C, PH_D, PH_F, PH_G, PH_H, Prepared, refl, sig_log, smooth01,
};
use rayon::prelude::*;

/// Вариант решения: без нагрева (`w_mech`) или с нагревом.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Variant {
    Mech,
    Heat,
}

/// Веса и маска одного варианта. `weights[k·n² + c]` (фаза-мажорно), Σ_k = 1 в каждом столбце.
#[derive(Clone, Debug)]
pub struct Classified {
    pub weights: Vec<f64>,
    /// Механические веса колонны ДО умножения на `r = (1−F)(1−G)`, сглаженные тем же гауссом, но не
    /// нормированные: `[g·n² + c]`, группы g = 0 (A+C), 1 (B), 2 (D+H). Нужны [`super::calm::mix`]
    /// для базового ветра колонны F, когда Σ механических весов → 0.
    pub base: Vec<f64>,
    pub freeze: Vec<u8>,
}

/// Оба варианта (как `AirPhase.result`: `weights`/`freeze` — нагрев, `*_mech` — без).
#[derive(Clone, Debug)]
pub struct PhaseMaps {
    pub heat: Classified,
    pub mech: Classified,
}

/// Сырые веса столбца `c` (K·n²-мажорно после `smooth`; здесь — по столбцам `[c][k]`).
#[inline]
fn raw_cell(p: &Prepared, v: Variant, c: usize) -> ([f64; K], [f64; 3]) {
    let a = &p.prm;
    let col = &p.cols;
    let heated = v == Variant::Heat && a.heated;
    let gact = v == Variant::Heat && a.gact;
    let ust = a.ustar;
    let hc = col.hc[c];
    let mut wh = a.wh;
    let mut wd = a.wd;
    if a.d_local {
        wd *= smooth01(0.0, a.d_ramp, a.hcd - hc);
    }
    let mut wc = 0.0;
    if a.c_wms > 0.0 {
        let x = (a.usat * col.sal[c]).max(1e-6);
        wc = (1.0 - wh) * (1.0 - wd) * sig_log(x, a.c_wms, a.c_wdec);
    }
    let mut wa = (1.0 - wh - wd - wc).max(0.0);
    let mut sl = smooth01(0.0, a.lee_depth, col.heff[c] - hc);
    let heat = col.heat[c];
    if heated {
        let steep = if col.s[c] < a.lee_steep {
            1.0
        } else {
            a.lee_hsk
        };
        sl *= 1.0 - smooth01(a.lee_hlo, a.lee_hhi, heat) * steep;
    }
    let wb = sl;
    wa *= 1.0 - sl;
    wc *= 1.0 - sl;
    wd *= 1.0 - sl;
    wh *= 1.0 - sl;
    let mut wfc = 0.0;
    if heated {
        let hk = col.hk[c];
        if ust > 0.0 {
            let zil = col.hbl[c] * a.kappa * a.grav * hk.max(0.0) / (a.theta0 * ust * ust * ust);
            wfc = if hk > 0.0 {
                sig_log(zil.max(1e-6), a.zil_c, a.w_ef)
            } else {
                0.0
            };
        } else {
            wfc = if heat > 0.0 { 1.0 } else { 0.0 };
        }
    }
    let wg = if gact { col.gw[c] } else { 0.0 };
    let r = (1.0 - wfc) * (1.0 - wg);
    let mut w = [0.0; K];
    w[PH_A] = wa * r;
    w[PH_B] = wb * r;
    w[PH_C] = wc * r;
    w[PH_D] = wd * r;
    w[PH_F] = wfc * (1.0 - wg);
    w[PH_G] = wg;
    w[PH_H] = wh * r;
    (w, [wa + wc, wb, wd + wh])
}

/// Сырые веса варианта `v` (K·n² не сглажены, Σ ≠ 1 до `smooth`), по столбцам: `[c][k]`.
pub fn raw_weights(p: &Prepared, v: Variant) -> Vec<[f64; K]> {
    (0..p.n2)
        .into_par_iter()
        .map(|c| raw_cell(p, v, c).0)
        .collect()
}

/// Сглаживание гауссом σ = `smooth_cells` (раздельно, отражение) без нормировки: `[c][k]` → `[k·n² + c]`.
fn smooth_planes<const N: usize>(p: &Prepared, raw: &[[f64; N]]) -> Vec<f64> {
    let (nx, ny, n2) = (p.nx, p.ny, p.n2);
    let gk = &p.gk;
    let r = (gk.len() / 2) as i64;
    let mut tmp = vec![0.0; N * n2];
    tmp.par_chunks_mut(nx).enumerate().for_each(|(row, out)| {
        let (k, j) = (row / ny, row % ny);
        for (i, o) in out.iter_mut().enumerate() {
            let mut s = 0.0;
            for q in -r..=r {
                s += gk[(q + r) as usize] * raw[j * nx + refl(i as i64 + q, nx)][k];
            }
            *o = s;
        }
    });
    let mut out = vec![0.0; N * n2];
    out.par_chunks_mut(nx).enumerate().for_each(|(row, o)| {
        let (k, j) = (row / ny, row % ny);
        for (i, v) in o.iter_mut().enumerate() {
            let mut s = 0.0;
            for q in -r..=r {
                s += gk[(q + r) as usize] * tmp[k * n2 + refl(j as i64 + q, ny) * nx + i];
            }
            *v = s.max(0.0);
        }
    });
    out
}

/// Сглаживание гауссом σ = `smooth_cells` (раздельно, отражение) и нормировка Σ = 1.
/// Вход — сырые веса `[c][k]`; выход — `[k·n² + c]`.
pub fn smooth(p: &Prepared, raw: &[[f64; K]]) -> Vec<f64> {
    let (nx, ny, n2) = (p.nx, p.ny, p.n2);
    let mut out = smooth_planes::<K>(p, raw);
    let mut den = vec![0.0; n2];
    den.par_chunks_mut(nx).enumerate().for_each(|(j, d)| {
        for (i, x) in d.iter_mut().enumerate() {
            let mut tot = 0.0;
            for k in 0..K {
                tot += out[k * n2 + j * nx + i];
            }
            *x = tot.max(1e-12);
        }
    });
    out.par_chunks_mut(nx).enumerate().for_each(|(row, o)| {
        let j = row % ny;
        for (i, v) in o.iter_mut().enumerate() {
            *v /= den[j * nx + i];
        }
    });
    out
}

/// Маска заморозки по итоговым весам: вся область (H + сильное D ≥ `freeze_w`); у варианта с нагревом
/// ещё F ≥ `freeze_w` при w* ≥ `k·U_sat` и G ≥ `freeze_w`.
pub fn freeze_mask(p: &Prepared, v: Variant, fin: &[f64]) -> Vec<u8> {
    let a = &p.prm;
    let n2 = p.n2;
    let ws_min = a.ws_over_u * a.usat;
    (0..n2)
        .into_par_iter()
        .map(|c| {
            let mut f = a.full;
            if v == Variant::Heat {
                let ff = fin[PH_F * n2 + c] >= a.frz_w && p.cols.wst[c] >= ws_min;
                f = f || ff || fin[PH_G * n2 + c] >= a.frz_w;
            }
            u8::from(f)
        })
        .collect()
}

/// Веса и маска одного варианта.
pub fn classify(p: &Prepared, v: Variant) -> Classified {
    let (raw, base): (Vec<[f64; K]>, Vec<[f64; 3]>) =
        (0..p.n2).into_par_iter().map(|c| raw_cell(p, v, c)).unzip();
    let weights = smooth(p, &raw);
    let base = smooth_planes::<3>(p, &base);
    let freeze = freeze_mask(p, v, &weights);
    Classified {
        weights,
        base,
        freeze,
    }
}

/// Оба варианта.
pub fn classify_pair(p: &Prepared) -> PhaseMaps {
    PhaseMaps {
        heat: classify(p, Variant::Heat),
        mech: classify(p, Variant::Mech),
    }
}

/// Доли фаз по площади (`stats.phase_frac`): среднее веса по столбцам, порядок `PHASES`.
#[cfg_attr(
    target_arch = "x86_64",
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
pub fn phase_fractions(weights: &[f64], n2: usize) -> [f64; K] {
    let mut f = [0.0; K];
    if n2 == 0 {
        return [f64::NAN; K];
    }
    for (x, w) in f.iter_mut().zip(weights.chunks_exact(n2)) {
        let s: f64 = w.iter().sum();
        *x = s / n2 as f64;
    }
    f
}

/// Доля замороженных столбцов (`stats.frozen_frac`).
pub fn frozen_fraction(freeze: &[u8]) -> f64 {
    let mut s = 0.0;
    for &b in freeze {
        s += f64::from(b) / freeze.len() as f64;
    }
    s
}
