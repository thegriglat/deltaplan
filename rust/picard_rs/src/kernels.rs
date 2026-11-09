//! Point-wise kernels of the iteration: boundary conditions, local K (`kloc`), momentum and
//! heat stencils. Direct port of the reference kernels (`air.py`, `_SRC`); `f32` arithmetic.

use crate::case::Consts;
use crate::util::Row;
use rayon::prelude::*;

const CHUNK: usize = 512;

/// Cell coordinates `(i, j, k)` of a flat halo index, advanced cell by cell so that a loop over
/// consecutive cells needs no integer division per cell.
#[derive(Clone, Copy)]
pub(crate) struct Pos {
    pub i: usize,
    pub j: usize,
    pub k: usize,
}

impl Pos {
    /// Coordinates of flat index `idx` in a grid with `nx`, `ny` cells per row/plane.
    #[inline(always)]
    pub(crate) fn at(idx: usize, nx: usize, ny: usize) -> Self {
        Self {
            i: idx % nx,
            j: (idx / nx) % ny,
            k: idx / (nx * ny),
        }
    }

    /// Moves to the next flat index.
    #[inline(always)]
    pub(crate) fn advance(&mut self, nx: usize, ny: usize) {
        self.i += 1;
        if self.i == nx {
            self.i = 0;
            self.j += 1;
            if self.j == ny {
                self.j = 0;
                self.k += 1;
            }
        }
    }
}

const G_OVER_T0: f32 = (9.81 / 300.0) as f32;

/// Velocity components (faces), each a halo array.
pub struct Vel<'a> {
    pub u: &'a [f32],
    pub v: &'a [f32],
    pub w: &'a [f32],
}

/// Sets the type-2 boundary faces of `u`, `v` from the hard boundary condition
/// (calm: zero) — reference `Air.apply_bc`.
pub fn apply_bc(k: &Consts, u: &mut [f32], v: &mut [f32]) {
    if k.u10_positive {
        for (q, &i) in k.b_u.iter().enumerate() {
            u[i] = k.fixed_u[q];
        }
        for (q, &i) in k.b_v.iter().enumerate() {
            v[i] = k.fixed_v[q];
        }
    } else {
        for &i in &k.b_u {
            u[i] = 0.0;
        }
        for &i in &k.b_v {
            v[i] = 0.0;
        }
    }
}

/// Local eddy viscosity (Prandtl-Blackadar mixing length with stability correction plus
/// horizontal Smagorinsky), updated with under-relaxation in air cells only
/// — reference kernel `kloc`. `nu` is vertical K, `nuh` is horizontal K_h.
#[cfg_attr(
    all(target_arch = "x86_64", not(feature = "base_only")),
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
fn kloc_chunk(k: &Consts, vel: &Vel, th: &[f32], start: usize, nu: &mut [f32], nuh: &mut [f32]) {
    let (nx, ny) = (k.nxh, k.nyh);
    let st = [1usize, nx, nx * ny];
    let h = [k.dx, k.dx, k.dz];
    let (u, v, w) = (vel.u, vel.v, vel.w);
    let f = [u, v, w];
    // Cell coordinates are advanced with the loop (one division per chunk, not per cell).
    let mut pos = Pos::at(start, nx, ny);
    for (di, (nu_i, nuh_i)) in nu.iter_mut().zip(nuh.iter_mut()).enumerate() {
        let idx = start + di;
        let (i, j, kk) = (pos.i, pos.j, pos.k);
        pos.advance(nx, ny);
        'cell: {
            if k.cell[idx] != 1 {
                break 'cell;
            }
            let cval = |a: usize, p: usize, q: usize| 0.5 * (f[a][p] + f[a][q]);
            let c = [
                cval(0, idx, idx + st[0]),
                cval(1, idx, idx + st[1]),
                cval(2, idx, idx + st[2]),
            ];
            let mut g = [[0.0f32; 3]; 3];
            for a in 0..3 {
                for d in 0..3 {
                    if a == d {
                        g[a][d] = (f[a][idx + st[a]] - f[a][idx]) / h[d];
                        continue;
                    }
                    let qm = idx - st[d];
                    let qp = idx + st[d];
                    let okm = k.cell[qm] != 0;
                    let okp = k.cell[qp] != 0;
                    let cm = if okm { cval(a, qm, qm + st[a]) } else { 0.0 };
                    let cp = if okp { cval(a, qp, qp + st[a]) } else { 0.0 };
                    g[a][d] = if okm && okp {
                        (cp - cm) / (2.0 * h[d])
                    } else if okp {
                        (cp - c[a]) / h[d]
                    } else if okm {
                        (c[a] - cm) / h[d]
                    } else {
                        0.0
                    };
                }
            }
            let s2 = 2.0 * (g[0][0] * g[0][0] + g[1][1] * g[1][1] + g[2][2] * g[2][2])
                + (g[0][1] + g[1][0]) * (g[0][1] + g[1][0])
                + (g[0][2] + g[2][0]) * (g[0][2] + g[2][0])
                + (g[1][2] + g[2][1]) * (g[1][2] + g[2][1]);
            let dm = k.cell[idx - st[2]] != 0;
            let dp = k.cell[idx + st[2]] != 0;
            let dth = if dm && dp {
                (th[idx + st[2]] - th[idx - st[2]]) / (2.0 * k.dz)
            } else if dp {
                (th[idx + st[2]] - th[idx]) / k.dz
            } else if dm {
                (th[idx] - th[idx - st[2]]) / k.dz
            } else {
                0.0
            };
            let n2 = G_OVER_T0 * (k.gam[kk] + dth);
            let s = s2.sqrt();
            let ri = n2 / if s2 > 1e-12 { s2 } else { 1e-12 };
            let fr = if ri > 0.0 {
                1.0 / ((1.0 + 5.0 * ri) * (1.0 + 5.0 * ri))
            } else {
                (1.0 - 16.0 * ri).sqrt()
            };
            let mut z = k.z_bot + (kk as f32 - 0.5) * k.dz - k.hcp[j * nx + i];
            if z < 0.5 * k.dz {
                z = 0.5 * k.dz;
            }
            let l = 1.0 / (1.0 / (0.4 * z) + 1.0 / k.lam[j * nx + i]);
            let mut kv = l * l * s * fr;
            let kb = k.nu_bg[idx];
            if kv < kb {
                kv = kb;
            }
            *nu_i += k.k_relax * (kv - *nu_i);
            let d2 = (g[0][0] - g[1][1]) * (g[0][0] - g[1][1])
                + (g[0][1] + g[1][0]) * (g[0][1] + g[1][0]);
            let mut kh = k.csdx2 * d2.sqrt();
            if kh < kv {
                kh = kv;
            }
            *nuh_i += k.k_relax * (kh - *nuh_i);
        }
    }
}

/// Everything the momentum stencil of one component reads.
pub struct MomIn<'a> {
    pub vel: Vel<'a>,
    pub p: &'a [f32],
    pub th: &'a [f32],
    pub nu: &'a [f32],
    pub nuh: &'a [f32],
}

/// Per-component constant inputs of the momentum stencil (type map, drag/sponge, background).
struct MomGeo<'a> {
    tt: &'a [u8],
    sp: &'a [f32],
    bg: Option<&'a [f32]>,
}

impl<'a> MomGeo<'a> {
    fn new(k: &'a Consts, comp: usize) -> Self {
        let tt: &[u8] = [&k.tu, &k.tv, &k.tw][comp];
        let (sp, bg): (&[f32], Option<&[f32]>) = match comp {
            0 => (&k.sp_u, Some(&k.ubg)),
            1 => (&k.sp_u, Some(&k.vbg)),
            _ => (&k.sp_w, k.nest.as_ref().map(|n| n.ubw.as_slice())),
        };
        Self { tt, sp, bg }
    }
}

/// Momentum stencil row (`C`, `b`) of component `COMP` (0 u, 1 v, 2 w) in cell `idx` — reference
/// kernel `build_mom` (first-order upwind, frozen transport velocity).
#[inline(always)]
fn mom_cell<const COMP: usize, const CUT: bool>(
    k: &Consts,
    m: &MomIn,
    geo: &MomGeo,
    inv_dtau: f32,
    (idx, kk): (usize, usize),
) -> Row {
    let comp = COMP;
    let (nx, ny) = (k.nxh, k.nyh);
    let st = [1usize, nx, nx * ny];
    let h = [k.dx, k.dx, k.dz];
    let f = [m.vel.u, m.vel.v, m.vel.w];
    let (tt, sp, bg) = (geo.tt, geo.sp, geo.bg);
    if tt[idx] != 1 {
        return [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, f[comp][idx]];
    }
    let sc = st[comp];
    let c0 = idx - sc;
    let c1 = idx;
    let mut a3 = [0.0f32; 3];
    a3[comp] = f[comp][idx];
    for d in 0..3 {
        if d == comp {
            continue;
        }
        let g = f[d];
        a3[d] = 0.25 * (g[c0] + g[c0 + st[d]] + g[c1] + g[c1 + st[d]]);
    }
    let mut diag = inv_dtau + sp[idx];
    let bgv = bg.map_or(0.0, |b| b[idx]);
    let mut rhs = f[comp][idx] * inv_dtau + sp[idx] * bgv;
    let mut cc = [0.0f32; 7];
    // PT2: flux weights A_open / V_open of the six sides (CUT only; the plain path has none).
    let wts = if CUT {
        k.cut.as_ref().map_or([1.0; 7], |c| {
            let w = &c.mw[comp][idx];
            [0.0, w[0], w[1], w[2], w[3], w[4], w[5]]
        })
    } else {
        [1.0; 7]
    };
    for d in 0..3 {
        let ih = 1.0 / h[d];
        let a = a3[d];
        let kk_arr = if d == 2 { m.nu } else { m.nuh };
        for s in 0..2usize {
            let o = 1 + 2 * d + s;
            let q = if s == 1 { idx + st[d] } else { idx - st[d] };
            let kf = if d == comp {
                kk_arr[if s == 1 { c1 } else { c0 }]
            } else if s == 1 {
                0.25 * (kk_arr[c0] + kk_arr[c1] + kk_arr[c0 + st[d]] + kk_arr[c1 + st[d]])
            } else {
                0.25 * (kk_arr[c0] + kk_arr[c1] + kk_arr[c0 - st[d]] + kk_arr[c1 - st[d]])
            };
            let (vis, aa) = if CUT {
                (kf * ih * ih * wts[o], a.abs() * wts[o])
            } else {
                (kf * ih * ih, a.abs())
            };
            let up = (s == 0 && a > 0.0) || (s == 1 && a < 0.0);
            if tt[q] == 0 {
                if d == comp {
                    diag += vis;
                    if up {
                        diag += aa * ih;
                    }
                }
            } else {
                diag += vis;
                let mut cn = -vis;
                if up {
                    diag += aa * ih;
                    cn -= aa * ih;
                }
                cc[o] = cn;
            }
        }
    }
    rhs -= (m.p[c1] - m.p[c0]) / h[comp];
    if CUT && let Some(cut) = k.cut.as_ref() {
        // PT2 wall friction along the wall: C_d |u_t| u_t |W| / V, implicit in the own component.
        let [cd, wv, n0, n1, n2] = cut.drag[comp][idx];
        if cd != 0.0 {
            let n = [n0, n1, n2];
            let an = a3[0] * n0 + a3[1] * n1 + a3[2] * n2;
            let t = [a3[0] - an * n0, a3[1] - an * n1, a3[2] - an * n2];
            let ut = (t[0] * t[0] + t[1] * t[1] + t[2] * t[2]).sqrt();
            let nc = n[comp];
            let cross = an - a3[comp] * nc;
            let g = cd * ut / k.dz * wv;
            diag += g * (1.0 - nc * nc);
            rhs += g * nc * cross;
        }
        if comp == 2 {
            rhs += G_OVER_T0 * 0.5 * (m.th[c0] + m.th[c1]);
            diag += k.cplz[kk];
            rhs += k.cplz[kk] * f[2][idx];
        }
    } else if comp < 2 {
        if tt[idx - st[2]] == 0 {
            let sp2 = a3[0] * a3[0] + a3[1] * a3[1];
            let cd = k.cd_col.as_ref().map_or(k.cd, |c| c[idx % (nx * ny)]);
            diag += cd * sp2.sqrt() / k.dz;
        }
    } else {
        rhs += G_OVER_T0 * 0.5 * (m.th[c0] + m.th[c1]);
        diag += k.cplz[kk];
        rhs += k.cplz[kk] * f[2][idx];
    }
    [diag, cc[1], cc[2], cc[3], cc[4], cc[5], cc[6], rhs]
}

/// Momentum stencils of all three components for the cells `start..start + cu.len()`: one pass,
/// the shared inputs (`nu`, `nuh`, `th`, `p`, velocities, masks) are read once per cell block.
#[cfg_attr(
    all(target_arch = "x86_64", not(feature = "base_only")),
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
fn build_all_mom_chunk(
    k: &Consts,
    m: &MomIn,
    start: usize,
    cu: &mut [Row],
    cv: &mut [Row],
    cw: &mut [Row],
) {
    let inv_dtau = 1.0 / k.dtau_u;
    let (gu, gv, gw) = (MomGeo::new(k, 0), MomGeo::new(k, 1), MomGeo::new(k, 2));
    let (nx, ny) = (k.nxh, k.nyh);
    let cut = k.cut.is_some();
    let mut pos = Pos::at(start, nx, ny);
    for (di, ((ru, rv), rw)) in cu
        .iter_mut()
        .zip(cv.iter_mut())
        .zip(cw.iter_mut())
        .enumerate()
    {
        let at = (start + di, pos.k);
        pos.advance(nx, ny);
        if cut {
            *ru = mom_cell::<0, true>(k, m, &gu, inv_dtau, at);
            *rv = mom_cell::<1, true>(k, m, &gv, inv_dtau, at);
            *rw = mom_cell::<2, true>(k, m, &gw, inv_dtau, at);
        } else {
            *ru = mom_cell::<0, false>(k, m, &gu, inv_dtau, at);
            *rv = mom_cell::<1, false>(k, m, &gv, inv_dtau, at);
            *rw = mom_cell::<2, false>(k, m, &gw, inv_dtau, at);
        }
    }
}

/// Source and background terms of one heat template.
pub struct HeatIn<'a> {
    pub vel: Vel<'a>,
    /// The scalar being solved (theta'_d or theta').
    pub x: &'a [f32],
    /// Heating, or heating minus theta'_d/tau for the full theta'.
    pub q: &'a [f32],
    /// Optional `(theta'_d, 1/tau)`: the source is then `q - theta'_d / tau` per cell, formed in
    /// the kernel (no array of the effective source).
    pub q_sub: Option<(&'a [f32], f32)>,
    /// `dtheta_bar/dz` per level for theta', `None` for theta'_d.
    pub gam: Option<&'a [f32]>,
    pub nu: &'a [f32],
    pub nuh: &'a [f32],
    /// 1/tau on the diagonal (theta'_d) or 0 (theta').
    pub inv_tau: f32,
    /// Sponge target (window: the parent's theta' / theta'_d); `None` = zero (domain).
    pub bg: Option<&'a [f32]>,
}

/// Heat stencil of one scalar — reference kernel `build_heat` (upwind transport in the
/// template, turbulent diffusion `K / Pr_t`, sponge toward a zero parent).
#[cfg_attr(
    all(target_arch = "x86_64", not(feature = "base_only")),
    multiversion::multiversion(targets("x86_64+avx2+fma"))
)]
fn build_heat_chunk(k: &Consts, hin: &HeatIn, start: usize, out: &mut [Row]) {
    let (nx, ny) = (k.nxh, k.nyh);
    let st = [1usize, nx, nx * ny];
    let h = [k.dx, k.dx, k.dz];
    let vel = [hin.vel.u, hin.vel.v, hin.vel.w];
    let inv_dtau = 1.0 / k.dtau_th;
    let mut pos = Pos::at(start, nx, ny);
    for (di, row) in out.iter_mut().enumerate() {
        let idx = start + di;
        let kk = pos.k;
        pos.advance(nx, ny);
        {
            if k.cell[idx] != 1 {
                *row = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, hin.x[idx]];
                continue;
            }
            let mut diag = inv_dtau + hin.inv_tau + k.spc[idx];
            let gterm = hin
                .gam
                .map_or(0.0, |g| g[kk] * 0.5 * (vel[2][idx] + vel[2][idx + st[2]]));
            let q = match hin.q_sub {
                Some((d, inv_tau)) => hin.q[idx] - d[idx] * inv_tau,
                None => hin.q[idx],
            };
            let mut rhs = hin.x[idx] * inv_dtau + q - gterm;
            if let Some(b) = hin.bg {
                rhs += k.spc[idx] * b[idx];
            }
            let mut cc = [0.0f32; 7];
            // PT2: face weights af / vf (cut cells only).
            let wts = k.cut.as_ref().map(|c| {
                let w = &c.cw[idx];
                [0.0, w[0], w[1], w[2], w[3], w[4], w[5]]
            });
            for d in 0..3 {
                let ih = 1.0 / h[d];
                let kk_arr = if d == 2 { hin.nu } else { hin.nuh };
                for s in 0..2usize {
                    let vo = if s == 1 {
                        vel[d][idx + st[d]]
                    } else {
                        -vel[d][idx]
                    };
                    let q = if s == 1 { idx + st[d] } else { idx - st[d] };
                    let mut cn = 0.0;
                    let wo = wts.map_or(1.0, |w| w[1 + 2 * d + s]);
                    let vo = if wts.is_some() { vo * wo } else { vo };
                    if vo > 0.0 {
                        diag += vo * ih;
                    } else {
                        cn += vo * ih;
                    }
                    if k.cell[q] != 0 {
                        let mut dif = 0.5 * (kk_arr[idx] + kk_arr[q]) * ih * ih * k.inv_prt;
                        if wts.is_some() {
                            dif *= wo;
                        }
                        diag += dif;
                        cn -= dif;
                    }
                    cc[1 + 2 * d + s] = cn;
                }
            }
            *row = [diag, cc[1], cc[2], cc[3], cc[4], cc[5], cc[6], rhs];
        }
    }
}

/// Local eddy viscosity, see [`kloc_chunk`]: chunks of cells in parallel.
pub fn kloc(k: &Consts, vel: &Vel, th: &[f32], nu: &mut [f32], nuh: &mut [f32]) {
    nu.par_chunks_mut(CHUNK)
        .zip(nuh.par_chunks_mut(CHUNK))
        .enumerate()
        .for_each(|(c, (nu_c, nuh_c))| kloc_chunk(k, vel, th, c * CHUNK, nu_c, nuh_c));
}

/// Momentum stencils of u, v, w in one pass, see [`build_all_mom_chunk`]: chunks of cells in
/// parallel, the three output templates are traversed together.
pub fn build_all_mom(k: &Consts, m: &MomIn, cu: &mut [Row], cv: &mut [Row], cw: &mut [Row]) {
    cu.par_chunks_mut(CHUNK)
        .zip(cv.par_chunks_mut(CHUNK))
        .zip(cw.par_chunks_mut(CHUNK))
        .enumerate()
        .for_each(|(c, ((u, v), w))| build_all_mom_chunk(k, m, c * CHUNK, u, v, w));
}

/// Heat stencil of one scalar, see [`build_heat_chunk`]: chunks of cells in parallel.
pub fn build_heat(k: &Consts, hin: &HeatIn, out: &mut [Row]) {
    out.par_chunks_mut(CHUNK)
        .enumerate()
        .for_each(|(c, oc)| build_heat_chunk(k, hin, c * CHUNK, oc));
}
