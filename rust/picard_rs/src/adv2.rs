//! Deferred second-order advection correction (PT3): port of the reference kernels `adv2_mom`
//! and `adv2_heat` (`air.py`). The templates stay first-order upwind (implicit); the correction
//! `D_2 f - D_1 f` of a slope-limited (MUSCL) upwind scheme is put on the right-hand side from
//! the previous iterate. Limiters: 0 linear upwind (Beam-Warming slope), 1 van Leer, 2 van
//! Albada (as air3d), 3 minmod (new: `phi(r) = max(0, min(1, r))`, Sweby 1984; van Leer 1979).

use crate::case::Consts;
use crate::kernels::{Pos, Vel};
use crate::util::Row;
use anyhow::{Result, bail};
use rayon::prelude::*;

const CHUNK: usize = 512;

/// Slope limiter of the second-order correction.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Limiter {
    Linear = 0,
    VanLeer = 1,
    VanAlbada = 2,
    MinMod = 3,
}

impl Limiter {
    /// From the `params.limiter` number.
    pub fn from_index(i: i64) -> Result<Self> {
        Ok(match i {
            0 => Self::Linear,
            1 => Self::VanLeer,
            2 => Self::VanAlbada,
            3 => Self::MinMod,
            _ => bail!("params.limiter must be 0..=3, got {i}"),
        })
    }

    /// From the CLI name (`linear|vanleer|vanalbada|minmod`).
    pub fn from_name(s: &str) -> Result<Self> {
        Ok(match s {
            "linear" => Self::Linear,
            "vanleer" => Self::VanLeer,
            "vanalbada" => Self::VanAlbada,
            "minmod" => Self::MinMod,
            _ => bail!("--adv2 must be off|linear|vanleer|vanalbada|minmod, got {s:?}"),
        })
    }

    /// Limited slope from the upwind difference `a` and the downwind difference `b`.
    #[inline(always)]
    pub fn slope(self, a: f32, b: f32) -> f32 {
        match self {
            Self::Linear => a,
            Self::VanLeer => {
                let ab = a * b;
                if ab > 0.0 { 2.0 * ab / (a + b) } else { 0.0 }
            }
            Self::VanAlbada => {
                let ab = a * b;
                let eps = 1e-12f32;
                if ab > 0.0 {
                    (a * (b * b + eps) + b * (a * a + eps)) / (a * a + b * b + 2.0 * eps)
                } else {
                    0.0
                }
            }
            // a * max(0, min(1, b / a)): the smaller of the two differences when they agree in sign.
            Self::MinMod => {
                if a * b > 0.0 {
                    if a.abs() <= b.abs() { a } else { b }
                } else {
                    0.0
                }
            }
        }
    }
}

/// Correction buffers of one run (halo layout) and the limiter.
pub struct Adv2 {
    pub lim: Limiter,
    /// Momentum corrections `u, v, w`.
    pub cm: [Vec<f32>; 3],
    /// Heat corrections for `theta'` and `theta'_d`.
    pub ct: Vec<f32>,
    pub ctd: Vec<f32>,
}

impl Adv2 {
    pub fn new(lim: Limiter, n: usize) -> Self {
        let z = || vec![0.0f32; n];
        Self {
            lim,
            cm: [z(), z(), z()],
            ct: z(),
            ctd: z(),
        }
    }
}

/// `rows[q].b -= corr[q]` (the correction enters the right-hand side with a minus sign).
pub fn sub_rhs(rows: &mut [Row], corr: &[f32]) {
    rows.par_chunks_mut(4096)
        .zip(corr.par_chunks(4096))
        .for_each(|(r, c)| {
            for (r, &c) in r.iter_mut().zip(c) {
                r[7] -= c;
            }
        });
}

/// Momentum correction of component `comp` (kernel `adv2_mom`): `sum_d |a_d| (D_2 - D_1) f`.
pub fn adv2_mom(k: &Consts, lim: Limiter, vel: &Vel, comp: usize, corr: &mut [f32]) {
    let cut = k.cut.as_ref();
    let tt: &[u8] = [&k.tu, &k.tv, &k.tw][comp];
    let f = [vel.u, vel.v, vel.w];
    corr.par_chunks_mut(CHUNK).enumerate().for_each(|(c, out)| {
        let (nx, ny, nz) = (k.nxh, k.nyh, k.nzh);
        let st = [1usize, nx, nx * ny];
        let len = [nx, ny, nz];
        let h = [k.dx, k.dx, k.dz];
        let start = c * CHUNK;
        let mut p = Pos::at(start, nx, ny);
        let ff = f[comp];
        for (di, o) in out.iter_mut().enumerate() {
            let idx = start + di;
            let ps = [p.i, p.j, p.k];
            p.advance(nx, ny);
            if tt[idx] != 1 {
                *o = 0.0;
                continue;
            }
            let c0 = idx - st[comp];
            let c1 = idx;
            let mut acc = 0.0f32;
            for d in 0..3 {
                let a = if d == comp {
                    ff[idx]
                } else {
                    let g = f[d];
                    0.25 * (g[c0] + g[c0 + st[d]] + g[c1] + g[c1 + st[d]])
                };
                if a == 0.0 {
                    continue;
                }
                let sgn: isize = if a > 0.0 { 1 } else { -1 };
                let pm2 = ps[d] as isize - 2 * sgn;
                let pp1 = ps[d] as isize + sgn;
                if pm2 < 0 || pm2 >= len[d] as isize || pp1 < 0 || pp1 >= len[d] as isize {
                    continue;
                }
                let s = st[d] as isize;
                let qm1 = (idx as isize - sgn * s) as usize;
                let qm2 = (idx as isize - 2 * sgn * s) as usize;
                let qp1 = (idx as isize + sgn * s) as usize;
                if tt[qm1] == 0 || tt[qm2] == 0 || tt[qp1] == 0 {
                    continue;
                }
                let (f0, fm1, fm2, fp1) = (ff[idx], ff[qm1], ff[qm2], ff[qp1]);
                let dd =
                    0.5 * (lim.slope(f0 - fm1, fp1 - f0) - lim.slope(fm1 - fm2, f0 - fm1)) / h[d];
                // PT4: with cut cells the correction enters with the weight A_open / V_open of
                // the upwind face of the control volume (that of the first-order flux).
                let w = cut.map_or(1.0, |c| c.mw[comp][idx][2 * d + usize::from(a < 0.0)]);
                acc += a.abs() * dd * w;
            }
            *o = acc;
        }
    });
}

/// Heat correction of the scalar `th` (kernel `adv2_heat`, flux form): per face
/// `v (f_high - f_upwind)`, signed by the side of the cell.
pub fn adv2_heat(k: &Consts, lim: Limiter, vel: &Vel, th: &[f32], corr: &mut [f32]) {
    let cut = k.cut.as_ref();
    let vv = [vel.u, vel.v, vel.w];
    corr.par_chunks_mut(CHUNK).enumerate().for_each(|(c, out)| {
        let (nx, ny, nz) = (k.nxh, k.nyh, k.nzh);
        let st = [1isize, nx as isize, (nx * ny) as isize];
        let len = [nx as isize, ny as isize, nz as isize];
        let h = [k.dx, k.dx, k.dz];
        let start = c * CHUNK;
        let mut p = Pos::at(start, nx, ny);
        for (di, o) in out.iter_mut().enumerate() {
            let idx = (start + di) as isize;
            let ps = [p.i as isize, p.j as isize, p.k as isize];
            p.advance(nx, ny);
            if k.cell[idx as usize] != 1 {
                *o = 0.0;
                continue;
            }
            let mut acc = 0.0f32;
            for d in 0..3 {
                for s in 0..2 {
                    // face between L and R = L + 1; our cell is R at s = 0, L at s = 1
                    let l = if s == 1 { idx } else { idx - st[d] };
                    let r = l + st[d];
                    let pl = if s == 1 { ps[d] } else { ps[d] - 1 };
                    let vf = vv[d][r as usize];
                    if vf == 0.0 {
                        continue;
                    }
                    let (u1, u2, d1, pu2) = if vf > 0.0 {
                        (l, l - st[d], r, pl - 1)
                    } else {
                        (r, r + st[d], l, pl + 2)
                    };
                    if pu2 < 0 || pu2 >= len[d] {
                        continue;
                    }
                    let (u1, u2, d1) = (u1 as usize, u2 as usize, d1 as usize);
                    if k.cell[u1] == 0 || k.cell[u2] == 0 || k.cell[d1] == 0 {
                        continue;
                    }
                    let fho = th[u1] + 0.5 * lim.slope(th[u1] - th[u2], th[d1] - th[u1]);
                    let fc = vf * (fho - th[u1]);
                    // PT4: weight af / vf of this face of the cell (as the upwind flux).
                    let w = cut.map_or(1.0, |c| c.cw[idx as usize][2 * d + s]);
                    acc += (if s == 1 { fc } else { -fc }) * w / h[d];
                }
            }
            *o = acc;
        }
    });
}
