//! Механизм A: линейная теория потока над рельефом [JH75, Sm80] (AP-17 `linear_a`): моды DCT-II
//! эффективного рельефа `T`, масштабы Джексона–Ханта, синтез возмущений на высотах
//! `agl_levels_m` и значение слоя в точке. Эталон — `AirPhase.modes`, `AirPhaseCpu.{synth,
//! mode_terms, slab_at}` и `AirPhase.u_prof`.
//!
//! DCT — та же наивная сумма с теми же таблицами `cos/sin(π·p·(i + ½)/n)` и тем же порядком
//! сложения, что в GDScript (быстрое DCT дало бы другие хвосты округления в малых элементах:
//! поэлементная сверка ≤ 1e-6 относительная). Параллельность rayon по независимым строкам и
//! высотам; каждое число считает один поток в фиксированном порядке — результат не зависит от
//! числа потоков.
use super::prepare::{KAPPA, Prepared, r32};
use rayon::prelude::*;
use std::f64::consts::PI;

/// Число компонент синтеза: δu, δv, δw, η.
pub const NCOMP: usize = 4;
/// Плоскости мод: амплитуда, ℓ, затем по 4 знакам (Re σ, Re m, Im m).
pub const MO_AMP: usize = 0;
pub const MO_ELL: usize = 1;
pub const MO_S0: usize = 2;
pub const NMO: usize = 14;
/// Знаки `(sk, sl)` четырёх продолжений DCT: (+,+), (−,+), (+,−), (−,−).
pub const SIGNS: [(i32, i32); 4] = [(1, 1), (-1, 1), (1, -1), (-1, -1)];

/// Профиль притока решателя `U(z) = U_sat·min((z/z_sat)^α, 1)` (`AirPhase.u_prof`).
#[inline]
pub fn u_prof(p: &Prepared, z: f64) -> f64 {
    if p.usat <= 0.0 {
        return 0.0;
    }
    p.usat * ((z.max(p.z0) / p.prm.zsat).powf(p.alpha)).min(1.0)
}

/// `cos(π·q/(2n))`, `q = p·(2i + 1) mod 4n` — без больших аргументов (`cosb`).
#[inline]
fn arg(n: usize, i: usize, p: usize) -> f64 {
    PI * ((p * (2 * i + 1)) % (4 * n)) as f64 / (2 * n) as f64
}

/// Таблица `t[a·n + b] = f(arg(n, a, b))`.
fn table(n: usize, f: fn(f64) -> f64) -> Vec<f64> {
    let mut t = vec![0.0; n * n];
    t.par_chunks_mut(n).enumerate().for_each(|(a, row)| {
        for (b, v) in row.iter_mut().enumerate() {
            *v = f(arg(n, a, b));
        }
    });
    t
}

/// Моды линейной теории: `NMO` плоскостей по `n²`, `[плоскость·n² + q·nx + p]`.
#[derive(Clone, Debug)]
pub struct Modes {
    pub n2: usize,
    pub data: Vec<f64>,
}

impl Modes {
    pub fn plane(&self, k: usize) -> &[f64] {
        &self.data[k * self.n2..(k + 1) * self.n2]
    }
    /// Плоскость знака `s` (0..4): 0 — Re σ, 1 — Re m, 2 — Im m.
    pub fn sign_plane(&self, s: usize, which: usize) -> &[f64] {
        self.plane(MO_S0 + 3 * s + which)
    }
}

/// Моды из `T` (`AirPhase.modes`): амплитуды DCT-II рельефа `t − ⟨t⟩`, масштабы Джексона–Ханта
/// `ℓ`, `h_m`, `U_ref = U(h_m)`, по 4 знакам Re σ и m (ветвь: волна вверх, затухание с высотой).
pub fn modes(p: &Prepared) -> Modes {
    let (nx, ny, n2) = (p.nx, p.ny, p.n2);
    let t = &p.cols.t;
    let mut mean = 0.0;
    for &v in t {
        mean += v / n2 as f64;
    }
    // ctx[i·nx + p] = cosb(nx, i, p)
    let ctx = table(nx, f64::cos);
    let cty = table(ny, f64::cos);
    // R[j, p] = Σ_i (t − ⟨t⟩)[j, i]·C[i, p]
    let mut r = vec![0.0; n2];
    r.par_chunks_mut(nx).enumerate().for_each(|(j, row)| {
        for (pp, o) in row.iter_mut().enumerate() {
            let mut s = 0.0;
            for i in 0..nx {
                s += (t[j * nx + i] - mean) * ctx[i * nx + pp];
            }
            *o = s;
        }
    });
    let mut out = vec![0.0; NMO * n2];
    {
        let amp = &mut out[..n2];
        let r = &r;
        // amp[q, p] = s_q² s_p² Σ_j C[j, q]·R[j, p]
        amp.par_chunks_mut(nx).enumerate().for_each(|(q, row)| {
            let sy = (if q == 0 { 1.0 } else { 2.0 }) / ny as f64;
            let mut acc = vec![0.0; nx];
            for j in 0..ny {
                let cy = cty[j * ny + q];
                for pp in 0..nx {
                    acc[pp] += cy * r[j * nx + pp];
                }
            }
            for (pp, o) in row.iter_mut().enumerate() {
                let sx = (if pp == 0 { 1.0 } else { 2.0 }) / nx as f64;
                *o = acc[pp] * sy * sx;
            }
        });
    }
    out[0] = 0.0;
    let a = &p.cfg.a;
    let z0 = p.z0;
    let nn = p.n_eff;
    let (ex, ey) = (p.ex, p.ey);
    for q in 0..ny {
        for pp in 0..nx {
            let c = q * nx + pp;
            let kx = PI * pp as f64 / (nx as f64 * p.dx);
            let ky = PI * q as f64 / (ny as f64 * p.dx);
            let mut km = (kx * kx + ky * ky).sqrt();
            if c == 0 {
                km = 1.0;
            }
            let big_l = 1.0 / km.max(1e-12);
            let mut ell = a.jh_ell0_m;
            let mut hm = a.jh_hm0_m;
            for _ in 0..a.jh_iters {
                ell = 2.0 * KAPPA * KAPPA * big_l / (ell.max(2.0 * z0) / z0).ln();
                hm = big_l / (hm.max(2.0 * z0) / z0).ln().sqrt();
            }
            ell = ell.max(2.0 * z0);
            hm = hm.max(2.0 * z0);
            out[MO_ELL * n2 + c] = ell;
            let uref = u_prof(p, hm).max(a.uref_min);
            let eps = uref / a.damp_m;
            for (s, &(sgx, sgy)) in SIGNS.iter().enumerate() {
                let aa = uref * (ex * f64::from(sgx) * kx + ey * f64::from(sgy) * ky);
                // σ = a − iε; σ² = (a² − ε²) − 2iaε; N²/σ² = N²·conj(σ²)/|σ²|²
                let s2r = aa * aa - eps * eps;
                let s2i = -2.0 * aa * eps;
                let s2m = s2r * s2r + s2i * s2i;
                let rr = nn * nn * s2r / s2m - 1.0;
                let ri = -nn * nn * s2i / s2m;
                let m2r = rr * km * km;
                let m2i = ri * km * km;
                let md = (m2r * m2r + m2i * m2i).sqrt();
                let mre = (0.5 * (md + m2r)).max(0.0).sqrt();
                let mim = (0.5 * (md - m2r)).max(0.0).sqrt();
                let sgn = if aa + 1e-30 >= 0.0 { 1.0 } else { -1.0 };
                out[(MO_S0 + 3 * s) * n2 + c] = aa;
                out[(MO_S0 + 3 * s + 1) * n2 + c] = mre.abs() * sgn;
                out[(MO_S0 + 3 * s + 2) * n2 + c] = mim.abs();
            }
        }
    }
    Modes { n2, data: out }
}

/// Для моды `c` на высоте `z`: `X = (Re Tee, Im Toe, Im Teo, Re Too)·amp` по компонентам δu, δv,
/// δw, η (16 чисел `[компонента·4 + часть]`). Передаточные функции [JH75, Sm80]: `ŵ = iσ·e^{imz_eff}`,
/// `(û, v̂) = −(k, l)·m·ŵ/|K|²·inner`, `w` — `e^{imz}` на самой высоте, `η = e^{imz}`.
pub fn mode_terms(p: &Prepared, md: &Modes, c: usize, z: f64, t: &mut [f64; 16]) {
    *t = [0.0; 16];
    if c == 0 {
        return;
    }
    let (nx, ny, n2) = (p.nx, p.ny, p.n2);
    let amp = md.data[MO_AMP * n2 + c];
    let ell = md.data[MO_ELL * n2 + c];
    let (pp, q) = (c % nx, c / nx);
    let dx = p.prm.dx;
    let kx0 = PI * pp as f64 / (nx as f64 * dx);
    let ky0 = PI * q as f64 / (ny as f64 * dx);
    let k2 = kx0 * kx0 + ky0 * ky0;
    let zeff = z.max(ell);
    let mut inner = 1.0;
    if z < ell {
        inner = (u_prof(p, z) / u_prof(p, ell).max(1e-6)).min(1.0);
    }
    for (s, &(sgx, sgy)) in SIGNS.iter().enumerate() {
        let sr = md.data[(MO_S0 + 3 * s) * n2 + c];
        let mr = md.data[(MO_S0 + 3 * s + 1) * n2 + c];
        let mi = md.data[(MO_S0 + 3 * s + 2) * n2 + c];
        let kx = f64::from(sgx) * kx0;
        let ly = f64::from(sgy) * ky0;
        let ea = (-mi * zeff).exp();
        let ezr = ea * (mr * zeff).cos();
        let ezi = ea * (mr * zeff).sin();
        // ŵ = iσ·e^{imz_eff}
        let wr = -sr * ezi;
        let wi = sr * ezr;
        // m·ŵ
        let mwr = mr * wr - mi * wi;
        let mwi = mr * wi + mi * wr;
        let f = inner / k2;
        let ur = -kx * mwr * f;
        let ui = -kx * mwi * f;
        let vr = -ly * mwr * f;
        let vi = -ly * mwi * f;
        let eb = (-mi * z).exp();
        let e2r = eb * (mr * z).cos();
        let e2i = eb * (mr * z).sin();
        let vals = [ur, ui, vr, vi, -sr * e2i, sr * e2r, e2r, e2i];
        let s_oe = f64::from(sgx);
        let s_eo = f64::from(sgy);
        let s_oo = f64::from(sgx * sgy);
        for comp in 0..4 {
            let re = vals[2 * comp];
            let im = vals[2 * comp + 1];
            // четверть суммы по знакам — чётная/нечётная части (AP-17 _synth)
            t[comp * 4] += re * amp / 4.0;
            t[comp * 4 + 1] += s_oe * im * amp / 4.0;
            t[comp * 4 + 2] += s_eo * im * amp / 4.0;
            t[comp * 4 + 3] += s_oo * re * amp / 4.0;
        }
    }
}

/// Возмущения A на высотах `agl_levels_m` над `T`: `[(l·4 + comp)·n² + c]`, высоты — как в
/// конфиге и в `Prm` (f32), см. [`Slab::lev`].
#[derive(Clone, Debug)]
pub struct Slab {
    pub n2: usize,
    pub nlev: usize,
    /// Высоты слоя, как слоты `prm` GDScript (округлены до f32): по ним `slab_at`.
    pub lev: Vec<f64>,
    pub data: Vec<f64>,
}

impl Slab {
    pub fn comp(&self, l: usize, comp: usize) -> &[f64] {
        let o = (l * NCOMP + comp) * self.n2;
        &self.data[o..o + self.n2]
    }
}

/// Синтез A (`AirPhaseCpu.synth`): обратное DCT мод на каждой высоте над `T`.
pub fn synth(p: &Prepared, md: &Modes) -> Slab {
    let (nx, ny, n2) = (p.nx, p.ny, p.n2);
    let nlev = p.lev.len();
    let cx = table(nx, f64::cos);
    let sx = table(nx, f64::sin);
    let cy = table(ny, f64::cos);
    let sy = table(ny, f64::sin);
    let mut out = vec![0.0; nlev * NCOMP * n2];
    out.par_chunks_mut(NCOMP * n2)
        .zip(p.lev.par_iter())
        .for_each(|(slab, &z)| {
            let mut x = vec![0.0; NCOMP * 4 * n2];
            let mut t = [0.0; 16];
            for c in 0..n2 {
                mode_terms(p, md, c, z, &mut t);
                for (q, &v) in t.iter().enumerate() {
                    x[q * n2 + c] = v;
                }
            }
            let mut pp = vec![0.0; n2];
            let mut qq = vec![0.0; n2];
            for comp in 0..NCOMP {
                let x1 = comp * 4 * n2;
                let (x0, x1_, x2, x3) = (
                    &x[x1..x1 + n2],
                    &x[x1 + n2..x1 + 2 * n2],
                    &x[x1 + 2 * n2..x1 + 3 * n2],
                    &x[x1 + 3 * n2..x1 + 4 * n2],
                );
                pp.par_chunks_mut(nx)
                    .zip(qq.par_chunks_mut(nx))
                    .enumerate()
                    .for_each(|(q, (prow, qrow))| {
                        for i in 0..nx {
                            let (mut sp, mut sq) = (0.0, 0.0);
                            for k in 0..nx {
                                let cc = cx[i * nx + k];
                                let ss = sx[i * nx + k];
                                let o = q * nx + k;
                                sp += x0[o] * cc - x1_[o] * ss;
                                sq += x2[o] * cc + x3[o] * ss;
                            }
                            prow[i] = sp;
                            qrow[i] = sq;
                        }
                    });
                let (pp, qq) = (&pp, &qq);
                slab[comp * n2..(comp + 1) * n2]
                    .par_chunks_mut(nx)
                    .enumerate()
                    .for_each(|(j, row)| {
                        row.fill(0.0);
                        for q in 0..ny {
                            let (a, b) = (cy[j * ny + q], sy[j * ny + q]);
                            for i in 0..nx {
                                row[i] += a * pp[q * nx + i] - b * qq[q * nx + i];
                            }
                        }
                    });
            }
        });
    Slab {
        n2,
        nlev,
        lev: p.lev.iter().map(|&z| r32(z)).collect(),
        data: out,
    }
}

/// Значение слоя A (δu, δv, δw, η) в столбце `c` на высоте `zt` над `T`: линейно между высотами;
/// ниже первой — закон стенки (горизонталь) или линейно к 0 (w, η); выше последней — верхнее.
/// Горизонталь — с ограничением `|δu_h| ≤ cap·U(z)` по уровню (AP-17 `linear_a cap_frac`).
pub fn slab_at(p: &Prepared, sl: &Slab, c: usize, zt: f64) -> [f64; NCOMP] {
    let n2 = sl.n2;
    let nlev = sl.nlev;
    let lev = &sl.lev;
    let l0 = lev[0];
    let zc = zt.clamp(l0, lev[nlev - 1]);
    let mut k = 0;
    while k + 2 < nlev && lev[k + 1] <= zc {
        k += 1;
    }
    let t = (zc - lev[k]) / (lev[k + 1] - lev[k]);
    let mut r = [0.0; NCOMP];
    for side in 0..2 {
        let l = k + side;
        let wt = if side == 1 { t } else { 1.0 - t };
        let d = |comp: usize| sl.data[(l * NCOMP + comp) * n2 + c];
        let (du, dv) = (d(0), d(1));
        let mag = (du * du + dv * dv).sqrt();
        let lim = p.prm.cap * u_prof(p, lev[l]);
        let fac = if mag > lim { lim / mag.max(1e-9) } else { 1.0 };
        r[0] += wt * du * fac;
        r[1] += wt * dv * fac;
        r[2] += wt * d(2);
        r[3] += wt * d(3);
    }
    if zt < l0 {
        let z0 = p.prm.z0;
        let fh = (zt.max(2.0 * z0) / z0).ln() / (l0 / z0).ln();
        let fw = (zt / l0).clamp(0.0, 1.0);
        r[0] *= fh;
        r[1] *= fh;
        r[2] *= fw;
        r[3] *= fw;
    }
    r
}

/// Поле A в точке: `(u, v, w, η)` = профиль притока по `e` + возмущение слоя на высоте
/// `zt = z − T` (`mech`, r[0..3]).
#[inline]
pub fn wind_a(p: &Prepared, sl: &Slab, c: usize, zmsl: f64) -> [f64; NCOMP] {
    let zt = zmsl - p.cols.t[c];
    let s = slab_at(p, sl, c, zt);
    let ub = u_prof(p, zt);
    [ub * p.prm.ex + s[0], ub * p.prm.ey + s[1], s[2], s[3]]
}
