//! Zebra line solvers (Thomas algorithm) and residual of a 7-point stencil system
//! `sum_o C_o x[idx + off_o] = b` on a flat `(nz, ny, nx)` array — reference
//! `line_thomas` and `resid7`.

use crate::util::{RHS, Row, Shared};
use rayon::prelude::*;

/// Shape `(nz, ny, nx)` of a flat array, index `(k * ny + j) * nx + i`.
pub type Shape = (usize, usize, usize);

/// Scratch arrays of the Thomas forward pass (same size as the array).
pub struct Scratch {
    cp: Vec<f32>,
    dp: Vec<f32>,
}

impl Scratch {
    /// Allocates scratch for `n` cells.
    pub fn new(n: usize) -> Self {
        Self {
            cp: vec![0.0; n],
            dp: vec![0.0; n],
        }
    }
}

/// One zebra half-sweep: all lines along `dir` (0 x, 1 y, 2 z) of the given `parity`
/// (sum of the two other indices mod 2) are solved exactly, off-line neighbours are
/// taken from the current `x`.
fn sweep_dir(
    rows: &[Row],
    x: &mut [f32],
    sc: &mut Scratch,
    shape: Shape,
    dir: usize,
    parity: usize,
) {
    let (nz, ny, nx) = shape;
    let n_all = nz * ny * nx;
    let (n, stride, nl, d1) = match dir {
        0 => (nx, 1usize, ny * nz, ny),
        1 => (ny, nx, nx * nz, nx),
        _ => (nz, nx * ny, nx * ny, nx),
    };
    let off: [isize; 7] = [
        0,
        -1,
        1,
        -(nx as isize),
        nx as isize,
        -((nx * ny) as isize),
        (nx * ny) as isize,
    ];
    let (lo, hi) = (1 + 2 * dir, 2 + 2 * dir);
    let xs = Shared::new(x);
    let cps = Shared::new(&mut sc.cp);
    let dps = Shared::new(&mut sc.dp);
    (0..nl).into_par_iter().with_min_len(8).for_each(|t| {
        let a1 = t % d1;
        let a2 = t / d1;
        if (a1 + a2) & 1 != parity {
            return;
        }
        let base = match dir {
            0 => (a2 * ny + a1) * nx,
            1 => a2 * ny * nx + a1,
            _ => a2 * nx + a1,
        };
        let (mut cprev, mut dprev) = (0.0f32, 0.0f32);
        for m in 0..n {
            let idx = base + m * stride;
            let row = &rows[idx];
            let mut r = row[RHS];
            for o in 1..7 {
                if o == lo || o == hi {
                    continue;
                }
                let c = row[o];
                if c != 0.0 {
                    let q = idx as isize + off[o];
                    if q >= 0 && (q as usize) < n_all {
                        // SAFETY: q lies on a line of the other colour, not written in this pass.
                        r -= c * unsafe { xs.get(q as usize) };
                    }
                }
            }
            let a = if m > 0 { row[lo] } else { 0.0 };
            let bb = row[0];
            let cc = if m + 1 < n { row[hi] } else { 0.0 };
            let den = bb - a * cprev;
            let cpv = cc / den;
            let dpv = (r - a * dprev) / den;
            // SAFETY: cells of this line are touched by this thread only.
            unsafe {
                cps.set(idx, cpv);
                dps.set(idx, dpv);
            }
            cprev = cpv;
            dprev = dpv;
        }
        let mut xn = 0.0f32;
        for m in (0..n).rev() {
            let idx = base + m * stride;
            // SAFETY: as above, this line belongs to this thread.
            unsafe {
                let v = dps.get(idx) - cps.get(idx) * xn;
                xs.set(idx, v);
                xn = v;
            }
        }
    });
}

/// Zebra sweeps over the directions `dirs` in order (parity 0 then 1 for each).
pub fn sweep(rows: &[Row], x: &mut [f32], sc: &mut Scratch, shape: Shape, dirs: &[usize]) {
    for &d in dirs {
        for par in 0..2 {
            sweep_dir(rows, x, sc, shape, d, par);
        }
    }
}

/// Residual `r = b - C x`.
pub fn resid(rows: &[Row], x: &[f32], shape: Shape, r: &mut [f32]) {
    let (nz, ny, nx) = shape;
    let n = nz * ny * nx;
    let off: [isize; 7] = [
        0,
        -1,
        1,
        -(nx as isize),
        nx as isize,
        -((nx * ny) as isize),
        (nx * ny) as isize,
    ];
    r.par_iter_mut()
        .enumerate()
        .with_min_len(256)
        .for_each(|(idx, ri)| {
            let row = &rows[idx];
            let mut s = 0.0f32;
            for (o, &of) in off.iter().enumerate() {
                let c = row[o];
                if c != 0.0 {
                    let q = idx as isize + of;
                    if q >= 0 && (q as usize) < n {
                        s += c * x[q as usize];
                    }
                }
            }
            *ri = row[RHS] - s;
        });
}
