//! PT6 v1: builder of the cut-cell fractions (`vf`, `af_u`, `af_v`, `af_w`) from a terrain raster.
//!
//! Port of `tools/research/picard_terrain/cut.py` (`fractions`, `type_height` and the full-cell /
//! face-floor rules of `build`) without changing the rules. Arithmetic in `f64`, storage in `f32`,
//! R1 halo layout `(nz + 2, ny + 2, nx + 2)`, index `(k * NY + j) * NX + i`.
//!
//! Model: the terrain between raster nodes is bilinear; a cell is sampled on a common fine
//! lattice of `n` points per cell edge (ends included, step `dx / (n - 1)`), so neighbours share
//! the points of a common face. `vf` is the trapezoid-weighted mean of the open height share
//! `clip((z_top - h) / dz, 0, 1)`; `af_w` the share of points of the bottom plane not below the
//! terrain (`h <= z`); `af_u`, `af_v` the mean open height share along the face edge.
//! The error of the shares is the sampling error of a piecewise-bilinear surface with `n` points
//! (the terrain is not resolved below `dx / (n - 1)`).

use anyhow::{Result, bail};
use rayon::prelude::*;

/// Minimum open volume share of an air cell.
pub const VF_MIN: f64 = 0.05;
/// Points per cell edge (ends included).
pub const SAMPLES: usize = 17;
/// Share given to a type-1 face with a zero share.
pub const AF_FLOOR: f32 = 1e-3;

/// Terrain raster: nodes `x0 + i*dx`, `y0 + j*dx`, index `[j*nx + i]`, metres above sea level.
#[derive(Clone, Copy)]
pub struct Raster<'a> {
    pub h: &'a [f32],
    pub nx: usize,
    pub ny: usize,
    pub x0: f64,
    pub y0: f64,
    pub dx: f64,
}

impl Raster<'_> {
    /// Bilinear height; outside the raster the nearest node (as `sample.Raster`).
    pub fn sample(&self, x: f64, y: f64) -> f64 {
        let fi = ((x - self.x0) / self.dx).clamp(0.0, self.nx as f64 - 1.000001);
        let fj = ((y - self.y0) / self.dx).clamp(0.0, self.ny as f64 - 1.000001);
        let (i0, j0) = (fi.floor() as usize, fj.floor() as usize);
        let (a, b) = (fi - i0 as f64, fj - j0 as f64);
        let h = |j: usize, i: usize| f64::from(self.h[j * self.nx + i]);
        (1.0 - b) * ((1.0 - a) * h(j0, i0) + a * h(j0, i0 + 1))
            + b * ((1.0 - a) * h(j0 + 1, i0) + a * h(j0 + 1, i0 + 1))
    }
}

/// Inner grid sizes; the cell with halo index `(i, j, k)` spans
/// `[x0 + (i-1)dx, x0 + i dx] x [y0 + (j-1)dx, ..] x [z_bot + (k-1)dz, z_bot + k dz]`.
#[derive(Clone, Copy, Debug)]
pub struct CutGrid {
    pub nx: usize,
    pub ny: usize,
    pub nz: usize,
    pub x0: f64,
    pub y0: f64,
    pub dx: f64,
    pub dz: f64,
    pub z_bot: f64,
}

impl CutGrid {
    /// Halo sizes `(NX, NY, NZ)`.
    pub fn dims(&self) -> (usize, usize, usize) {
        (self.nx + 2, self.ny + 2, self.nz + 2)
    }
}

/// Fractions on the R1 halo layout.
#[derive(Clone, Debug)]
pub struct Fractions {
    pub vf: Vec<f32>,
    pub af_u: Vec<f32>,
    pub af_v: Vec<f32>,
    pub af_w: Vec<f32>,
}

/// Counters of [`finish`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FinishStats {
    pub n_snap_full: usize,
    pub n_face_floor: usize,
    pub n_cut_cells: usize,
}

/// `vf` to f32 without rounding a share below 1 up to 1 (`finish` counts such cells as snapped).
fn store_vf(v: f64) -> f32 {
    let x = v as f32;
    if x >= 1.0 && v < 1.0 {
        1.0 - f32::EPSILON / 2.0
    } else {
        x
    }
}

/// Trapezoid weights of `n` points on an edge (ends half), summing to 1.
fn weights(n: usize) -> Vec<f64> {
    let m = (n - 1) as f64;
    (0..n)
        .map(|a| {
            if a == 0 || a == n - 1 {
                0.5 / m
            } else {
                1.0 / m
            }
        })
        .collect()
}

/// Copy the second row into the first (`first`) and the last-but-one into the last (`last`).
fn halo_rows(p: &mut [f32], nxh: usize, nyh: usize, first: bool, last: bool) {
    if first {
        p.copy_within(nxh..2 * nxh, 0);
    }
    if last {
        p.copy_within((nyh - 2) * nxh..(nyh - 1) * nxh, (nyh - 1) * nxh);
    }
}

fn halo_cols(p: &mut [f32], nxh: usize, first: bool, last: bool) {
    for row in p.chunks_mut(nxh) {
        if first {
            row[0] = row[1];
        }
        if last {
            row[nxh - 1] = row[nxh - 2];
        }
    }
}

/// Fractions of every cell (with the halo) from the raster, `n` points per cell edge.
pub fn fractions(r: &Raster, g: &CutGrid, n: usize) -> Fractions {
    assert!(n >= 2, "samples per edge must be >= 2");
    let m = n - 1;
    let (nxh, nyh, nzh) = g.dims();
    let (nxp, nyp) = (g.nx * m + 1, g.ny * m + 1);
    let step = g.dx / m as f64;
    // terrain heights on the point lattice, once for all layers
    let mut hh = vec![0f64; nxp * nyp];
    hh.par_chunks_mut(nxp).enumerate().for_each(|(jj, row)| {
        let y = g.y0 + jj as f64 * step;
        for (ii, v) in row.iter_mut().enumerate() {
            *v = r.sample(g.x0 + ii as f64 * step, y);
        }
    });
    // min / max of the points of every cell column: layers fully above / below are filled directly
    let mut bmin = vec![0f64; g.nx * g.ny];
    let mut bmax = vec![0f64; g.nx * g.ny];
    bmin.par_chunks_mut(g.nx)
        .zip(bmax.par_chunks_mut(g.nx))
        .enumerate()
        .for_each(|(j, (lo, hi))| {
            for i in 0..g.nx {
                let (mut a, mut b) = (f64::INFINITY, f64::NEG_INFINITY);
                for jj in j * m..=j * m + m {
                    for &h in &hh[jj * nxp + i * m..=jj * nxp + i * m + m] {
                        a = a.min(h);
                        b = b.max(h);
                    }
                }
                lo[i] = a;
                hi[i] = b;
            }
        });
    let wt = weights(n);
    let total = nxh * nyh * nzh;
    let mut vf = vec![0f32; total];
    let mut au = vec![0f32; total];
    let mut av = vec![0f32; total];
    let mut aw = vec![0f32; total];
    vf.par_chunks_mut(nxh)
        .zip(au.par_chunks_mut(nxh))
        .zip(av.par_chunks_mut(nxh))
        .zip(aw.par_chunks_mut(nxh))
        .enumerate()
        .for_each(|(row, (((vr, ur), wr), qr))| {
            let (k, jh) = (row / nyh, row % nyh);
            if jh == 0 {
                return;
            }
            let j = jh - 1; // cell row 0..=ny (ny: only the v faces)
            let zlo = g.z_bot + (k as f64 - 1.0) * g.dz;
            let zhi = zlo + g.dz;
            let open = |h: f64| ((zhi - h) / g.dz).clamp(0.0, 1.0);
            for i in 0..=g.nx {
                if j < g.ny {
                    // u face at x = x0 + i*dx: mean over the n points along y
                    let mut s = 0.0;
                    for b in 0..n {
                        s += wt[b] * open(hh[(j * m + b) * nxp + i * m]);
                    }
                    ur[i + 1] = s as f32;
                }
                if i < g.nx {
                    // v face at y = y0 + j*dx: mean over the n points along x
                    let mut s = 0.0;
                    let base = j * m * nxp + i * m;
                    for a in 0..n {
                        s += wt[a] * open(hh[base + a]);
                    }
                    wr[i + 1] = s as f32;
                    if j < g.ny {
                        let c = j * g.nx + i;
                        if zhi <= bmin[c] {
                            // whole column of points above the layer: nothing open
                        } else if zlo >= bmax[c] {
                            vr[i + 1] = 1.0;
                            qr[i + 1] = 1.0;
                        } else {
                            let (mut sv, mut sw) = (0.0, 0.0);
                            for b in 0..n {
                                let base = (j * m + b) * nxp + i * m;
                                let (mut tv, mut tw) = (0.0, 0.0);
                                for a in 0..n {
                                    let h = hh[base + a];
                                    tv += wt[a] * open(h);
                                    if h <= zlo {
                                        tw += wt[a];
                                    }
                                }
                                sv += wt[b] * tv;
                                sw += wt[b] * tw;
                            }
                            vr[i + 1] = store_vf(sv);
                            qr[i + 1] = sw as f32;
                        }
                    }
                }
            }
        });
    // halo: copy of the neighbouring inner cell / face along the normal
    let plane = nxh * nyh;
    vf.par_chunks_mut(plane)
        .zip(au.par_chunks_mut(plane))
        .zip(av.par_chunks_mut(plane))
        .zip(aw.par_chunks_mut(plane))
        .for_each(|(((a, u), v), w)| {
            for p in [a, w] {
                halo_rows(p, nxh, nyh, true, true);
                halo_cols(p, nxh, true, true);
            }
            halo_cols(u, nxh, true, false);
            halo_rows(u, nxh, nyh, true, true);
            halo_rows(v, nxh, nyh, true, false);
            halo_cols(v, nxh, true, true);
        });
    Fractions {
        vf,
        af_u: au,
        af_v: av,
        af_w: aw,
    }
}

/// `(ny, nx)` bottoms of the first air cell (`vf >= vf_min`, k >= 1) of every column, `[j*nx + i]`.
/// A column without an open cell, or with `vf` crossing `vf_min` downwards along k, is an error.
pub fn type_height(g: &CutGrid, vf: &[f32], vf_min: f64) -> Result<Vec<f64>> {
    let (nxh, nyh, nzh) = g.dims();
    if vf.len() != nxh * nyh * nzh {
        bail!("type_height: vf length {} != {}", vf.len(), nxh * nyh * nzh);
    }
    let mut hc = vec![0f64; g.nx * g.ny];
    // hc holds the first open layer index (0 = none yet) until the end
    hc.par_chunks_mut(g.nx)
        .enumerate()
        .try_for_each(|(j, row)| -> Result<()> {
            for k in 1..=g.nz {
                let base = (k * nyh + j + 1) * nxh + 1;
                for (i, c) in row.iter_mut().enumerate() {
                    let open = f64::from(vf[base + i]) >= vf_min;
                    if open && *c == 0.0 {
                        *c = k as f64;
                    } else if !open && *c != 0.0 {
                        bail!("type_height: vf not monotone in column (i={i}, j={j}) at k={k}");
                    }
                }
            }
            for (i, c) in row.iter_mut().enumerate() {
                if *c == 0.0 {
                    bail!("type_height: column without an open cell (i={i}, j={j})");
                }
                *c = g.z_bot + (*c - 1.0) * g.dz;
            }
            Ok(())
        })?;
    Ok(hc)
}

/// After the types: full cell (`cell == 1 && vf >= 1 - 1e-6`: `vf` and its 6 faces become 1),
/// then the face floor (type 1 and share <= 0: `AF_FLOOR`). Arrays have the halo layout.
pub fn finish(
    g: &CutGrid,
    f: &mut Fractions,
    cell: &[u8],
    tu: &[u8],
    tv: &[u8],
    tw: &[u8],
) -> FinishStats {
    let (nxh, nyh, nzh) = g.dims();
    let n = nxh * nyh * nzh;
    for len in [f.vf.len(), cell.len(), tu.len(), tv.len(), tw.len()] {
        assert_eq!(len, n, "finish: array length");
    }
    let mut st = FinishStats::default();
    let sy = nxh;
    let sz = nxh * nyh;
    for q in 0..n {
        if cell[q] == 1 && f64::from(f.vf[q]) >= 1.0 - 1e-6 {
            if f.vf[q] < 1.0 {
                st.n_snap_full += 1;
            }
            f.vf[q] = 1.0;
            f.af_u[q] = 1.0;
            f.af_v[q] = 1.0;
            f.af_w[q] = 1.0;
            if q % nxh + 1 < nxh {
                f.af_u[q + 1] = 1.0;
            }
            if (q / sy) % nyh + 1 < nyh {
                f.af_v[q + sy] = 1.0;
            }
            if q / sz + 1 < nzh {
                f.af_w[q + sz] = 1.0;
            }
        }
    }
    for (a, t) in [(&mut f.af_u, tu), (&mut f.af_v, tv), (&mut f.af_w, tw)] {
        for (x, &ty) in a.iter_mut().zip(t) {
            if ty == 1 && *x <= 0.0 {
                *x = AF_FLOOR;
                st.n_face_floor += 1;
            }
        }
    }
    for k in 1..=g.nz {
        for j in 1..=g.ny {
            let b = (k * nyh + j) * nxh;
            for q in b + 1..=b + g.nx {
                if cell[q] == 1 && f64::from(f.vf[q]) < 1.0 - 1e-6 {
                    st.n_cut_cells += 1;
                }
            }
        }
    }
    st
}
