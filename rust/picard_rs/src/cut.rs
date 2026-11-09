//! Cut cells (PT2, picard-terrain): FAVOR / porosity (Hirt & Sicilian 1985; Hirt 1993).
//!
//! The case carries the open (above the sub-grid terrain) fractions of the cell volumes `vf` and
//! of the MAC faces `af_u`, `af_v`, `af_w` (R1 layout with halo). With `params.cut_cells` the
//! solver uses them as follows (nothing else changes; without the flag none of this is read):
//!
//! - mass: the continuity residual of a cell is `sum(+-af * u / h)` over its six faces, per unit
//!   of the full cell volume; the projection conductances (SIMPLEC `Kx, Ky, Kz` of the case) are
//!   multiplied by the face fraction on the finest level, the coarse levels are built from the
//!   products as before; the velocity correction itself is `K * grad(phi)` (the face velocity is
//!   that of the open part, the flux is `af * u * A`);
//! - momentum and heat: every face flux of a control volume (upwind transport and turbulent
//!   diffusion) is multiplied by `A_open / V_open` of that control volume (`A_open / A`,
//!   `V_open / V` from the fractions), the pseudo-time, sponge, pressure gradient and buoyancy
//!   terms stay per unit volume; the momentum control volume of a face spans the halves of its
//!   two cells: `V = (vf[c0] + vf[c1]) / 2`, side faces through the cell centres the mean of the
//!   two faces of that cell, side faces normal to another axis the mean of the two faces there;
//! - wall friction: the wall vector of a cell is `-sum(af * A * n)` over its faces (closed
//!   surface), plus the open part of a closed bottom face (a ground cell below: `vf < vf_min`,
//!   folded into the ground). The momentum control volume takes the mean of its two cells, the
//!   bottom part as the reference rule (any closed face below: the larger open part); the stress
//!   `C_d |u_t| u_t` acts along the wall (tangential part of the frozen transport velocity),
//!   `C_d = (kappa / ln(d / z0))^2` with `d = V_open / (2 |W|)` (half the mean fluid thickness
//!   normal to the wall; `dz/2` for a full cell on a flat floor), `d >= e * z0`. The normal
//!   part is the impermeability carried by the fractions (no penalty).
//!
//! With all fractions 1 every weight is 1 and the friction is the reference one (`C_d` of
//! `dz/2` on faces with a closed face below), so the iteration repeats the plain one to round-off.

use crate::case::Case;
use anyhow::{Result, bail};

const KAPPA: f64 = 0.4;

/// Outward flux through the top boundary faces of a window (type 2 `w` faces), in units of
/// `dx*dz`: the faces carry `Case.nest.ubw`, sign `-1` when the cell of the face is air.
fn nest_top(c: &Case, cell: &[u8], tw: &[u8], af_w: &[f32]) -> f64 {
    let Some(nb) = &c.nest else { return 0.0 };
    if nb.ubw.len() != af_w.len() || tw.len() != af_w.len() {
        return 0.0;
    }
    let r = f64::from(c.dx) / f64::from(c.dz);
    let mut t = 0.0f64;
    for q in 0..af_w.len() {
        if tw[q] == 2 {
            let s = if cell[q] == 1 { -1.0 } else { 1.0 };
            t += s * f64::from(nb.ubw[q]) * f64::from(af_w[q]) * r;
        }
    }
    t
}

/// Fractions and the derived per-face constants of the cut-cell scheme.
pub struct Cut {
    /// Open volume fraction of the cells.
    pub vf: Vec<f32>,
    /// Open area fractions of the `u`, `v`, `w` faces.
    pub af: [Vec<f32>; 3],
    /// Projection conductances times the face fractions (`Kx*af_u`, `Ky*af_v`, `Kz*af_w`).
    pub kmg: [Vec<f32>; 3],
    /// Wall friction per face of each component: `[C_d, |W| / V, n_x, n_y, n_z]` (`|W|` in
    /// units of `dx^2`, `V` the open volume fraction; the term is `C_d |u_t| / dz * |W| / V`,
    /// for a full cell on a flat floor bit for bit the reference one); zero without a wall.
    pub drag: [Vec<[f32; 5]>; 3],
    /// Number of faces with wall friction per component (report).
    pub n_drag: [usize; 3],
    /// Flux weights `A_open / V_open` of the six sides of the momentum control volume of each
    /// face (precomputed once: they are constants of the case; slot `2 d + s`, `s` = 0 low side).
    pub mw: [Vec<[f32; 6]>; 3],
    /// Flux weights `af / vf` of the six faces of each cell (heat).
    pub cw: Vec<[f32; 6]>,
    /// Window (`Case.nest`): outward volume flux through the type 2 `w` faces (top) in units
    /// of the side-face area `dx*dz`, `sum s * ubw * af_w * dx / dz`; 0 without a window.
    pub nest_top: f64,
}

impl Cut {
    /// Reads the fractions of `c` (an error when one is missing) and builds the constants.
    #[allow(clippy::too_many_arguments)]
    pub fn from_case(c: &Case, cell: &[u8], tt: [&[u8]; 3], kxyz: [&[f32]; 3]) -> Result<Self> {
        let n3 = c.n3();
        let get = |name: &str| -> Result<Vec<f32>> {
            match c.arrays.get(name) {
                Some(a) if a.len() == n3 => Ok(a.clone()),
                Some(_) => bail!("cut_cells: array {name}: length != NX*NY*NZ"),
                None => {
                    bail!("cut_cells: params.cut_cells = true but the case has no array '{name}'")
                }
            }
        };
        let vf = get("vf")?;
        let af = [get("af_u")?, get("af_v")?, get("af_w")?];
        for (nm, a) in [
            ("vf", &vf),
            ("af_u", &af[0]),
            ("af_v", &af[1]),
            ("af_w", &af[2]),
        ] {
            if a.iter()
                .any(|x| !(x.is_finite() && (-1e-6..=1.0 + 1e-6).contains(x)))
            {
                bail!("cut_cells: {nm} outside [0, 1]");
            }
        }
        let kmg = [0, 1, 2].map(|d| {
            kxyz[d]
                .iter()
                .zip(&af[d])
                .map(|(&k, &a)| k * a)
                .collect::<Vec<f32>>()
        });
        let (nx, ny) = (c.nxh, c.nyh);
        let st = [1usize, nx, nx * ny];
        let (dx, dz) = (f64::from(c.dx), f64::from(c.dz));
        // Wall vector of the cut part of each air cell, in units of dx^2 (x, y faces: dx*dz).
        let wall = |q: usize| -> [f64; 3] {
            let r = dz / dx;
            [
                -(f64::from(af[0][q + st[0]]) - f64::from(af[0][q])) * r,
                -(f64::from(af[1][q + st[1]]) - f64::from(af[1][q])) * r,
                -(f64::from(af[2][q + st[2]]) - f64::from(af[2][q])),
            ]
        };
        let mut drag = [
            vec![[0.0f32; 5]; n3],
            vec![[0.0f32; 5]; n3],
            vec![[0.0f32; 5]; n3],
        ];
        let mut n_drag = [0usize; 3];
        let (cd0, cd_col) = (c.cd, c.cd_col.as_deref());
        for comp in 0..3 {
            let t = tt[comp];
            for idx in 0..n3 {
                if t[idx] != 1 {
                    continue;
                }
                let (c0, c1) = (idx - st[comp], idx);
                let (w0, w1) = (wall(c0), wall(c1));
                let mut w = [
                    0.5 * (w0[0] + w1[0]),
                    0.5 * (w0[1] + w1[1]),
                    0.5 * (w0[2] + w1[2]),
                ];
                if comp < 2 && idx >= st[2] && t[idx - st[2]] == 0 {
                    // Closed floor below (reference rule): the open part of a closed bottom face.
                    let mut ab = 0.0f64;
                    for q in [c0, c1] {
                        if q >= st[2] && cell[q - st[2]] == 0 {
                            ab = ab.max(f64::from(af[2][q]));
                        }
                    }
                    w[2] -= ab;
                }
                let wn = (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).sqrt();
                if wn < 1e-9 {
                    continue;
                }
                let v = (0.5 * (f64::from(vf[c0]) + f64::from(vf[c1]))).max(1e-6);
                // Reference coefficient of the column (explicit `cd`, `cd_col` or from `z0`) is
                // that of the half layer dz/2; its roughness z0e follows from the log law, and
                // the cut cell uses the same law at d = V_open / (2 |W|):
                // ln(d / z0e) = ln(2 d / dz) + kappa / sqrt(cd_ref), at least 1 (d >= e z0e).
                let cd_ref = f64::from(cd_col.map_or(cd0, |m| m[idx % (nx * ny)]));
                let l = (KAPPA / cd_ref.sqrt() + (v / wn).ln()).max(1.0);
                let cd = (KAPPA / l).powi(2);
                drag[comp][idx] = [
                    cd as f32,
                    (wn / v) as f32,
                    (w[0] / wn) as f32,
                    (w[1] / wn) as f32,
                    (w[2] / wn) as f32,
                ];
                n_drag[comp] += 1;
            }
        }
        let nest_top_flux = nest_top(c, cell, tt[2], &af[2]);
        let mut cut = Self {
            vf,
            af,
            kmg,
            drag,
            n_drag,
            mw: [Vec::new(), Vec::new(), Vec::new()],
            cw: Vec::new(),
            nest_top: nest_top_flux,
        };
        // Weights of faces and cells inside the halo ring only (the stencils never read others).
        let lo = st[0] + st[1] + st[2];
        let hi = n3.saturating_sub(lo);
        for comp in 0..3 {
            cut.mw[comp] = (0..n3)
                .map(|q| {
                    if q < lo || q >= hi || tt[comp][q] != 1 {
                        return [0.0; 6];
                    }
                    let w = cut.mom_weights(comp, q, st);
                    [w[1], w[2], w[3], w[4], w[5], w[6]]
                })
                .collect();
        }
        cut.cw = (0..n3)
            .map(|q| {
                if q < lo || q >= hi || cell[q] != 1 {
                    return [0.0; 6];
                }
                let w = cut.cell_weights(q, st);
                [w[1], w[2], w[3], w[4], w[5], w[6]]
            })
            .collect();
        Ok(cut)
    }

    /// Flux weights `A_open / V_open` of the six sides (slots 1..=6 of a row) of the momentum
    /// control volume of face `idx` of component `comp`.
    #[inline(always)]
    pub fn mom_weights(&self, comp: usize, idx: usize, st: [usize; 3]) -> [f32; 7] {
        let sc = st[comp];
        let (c0, c1) = (idx - sc, idx);
        let iv = 2.0 / (self.vf[c0] + self.vf[c1]).max(1e-6);
        let mut w = [0.0f32; 7];
        for d in 0..3 {
            let a = &self.af[d];
            let (am, ap) = if d == comp {
                (0.5 * (a[c0] + a[c1]), 0.5 * (a[c1] + a[c1 + sc]))
            } else {
                (0.5 * (a[c0] + a[c1]), 0.5 * (a[c0 + st[d]] + a[c1 + st[d]]))
            };
            w[1 + 2 * d] = am * iv;
            w[2 + 2 * d] = ap * iv;
        }
        w
    }

    /// Flux weights `af / vf` of the six faces of cell `idx` (heat).
    #[inline(always)]
    pub fn cell_weights(&self, idx: usize, st: [usize; 3]) -> [f32; 7] {
        let iv = 1.0 / self.vf[idx].max(1e-6);
        let mut w = [0.0f32; 7];
        for d in 0..3 {
            w[1 + 2 * d] = self.af[d][idx] * iv;
            w[2 + 2 * d] = self.af[d][idx + st[d]] * iv;
        }
        w
    }

    /// Rescales the outflow values of the boundary faces so that the net volume flux through
    /// the open parts is zero (the reference balances the plain face areas).
    pub fn rebalance(
        &self,
        (nxh, nyh): (usize, usize),
        b_u: &[usize],
        fixed_u: &mut [f32],
        b_v: &[usize],
        fixed_v: &mut [f32],
    ) {
        // Outward normal sign: west/south boundary faces have index 1 along their axis.
        let sgn_u = |q: usize| if q % nxh == 1 { -1.0 } else { 1.0 };
        let sgn_v = |q: usize| if (q / nxh) % nyh == 1 { -1.0 } else { 1.0 };
        let (mut fin, mut fout) = (0.0f64, 0.0f64);
        for (b, f, a, sg) in [
            (b_u, &*fixed_u, &self.af[0], &sgn_u as &dyn Fn(usize) -> f64),
            (b_v, &*fixed_v, &self.af[1], &sgn_v),
        ] {
            for (n, &q) in b.iter().enumerate() {
                let fl = sg(q) * f64::from(f[n]) * f64::from(a[q]);
                if fl > 0.0 {
                    fout += fl;
                } else {
                    fin -= fl;
                }
            }
        }
        // A window carries the flux of its top (`nest.ubw`): the sides balance against it.
        let top = self.nest_top;
        let r = if top == 0.0 {
            fin / fout
        } else {
            (fin + (-top).max(0.0) - top.max(0.0)) / fout
        };
        // Already balanced to the f32 round-off of the case (all fractions 1): keep the values.
        if !(r.is_finite() && r > 0.0) || (r - 1.0).abs() < 1e-6 {
            return;
        }
        for (b, f, a, sg) in [
            (b_u, fixed_u, &self.af[0], &sgn_u as &dyn Fn(usize) -> f64),
            (b_v, fixed_v, &self.af[1], &sgn_v),
        ] {
            for (n, &q) in b.iter().enumerate() {
                if sg(q) * f64::from(f[n]) * f64::from(a[q]) > 0.0 {
                    f[n] = (f64::from(f[n]) * r) as f32;
                }
            }
        }
    }
}
