//! Zebra line solvers (Thomas algorithm) and residual of a 7-point stencil system
//! `sum_o C_o x[idx + off_o] = b` on a flat `(nz, ny, nx)` array — reference
//! `line_thomas` and `resid7`.

use crate::util::{RHS, Row, Shared, fmadd};
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

/// True when neighbour `o` (1 -x, 2 +x, 3 -y, 4 +y, 5 -z, 6 +z) of flat cell `idx` is inside the grid.
fn in_grid(idx: usize, o: usize, (nz, ny, nx): Shape) -> bool {
    let (i, j, k) = (idx % nx, (idx / nx) % ny, idx / (nx * ny));
    match o {
        1 => i > 0,
        2 => i + 1 < nx,
        3 => j > 0,
        4 => j + 1 < ny,
        5 => k > 0,
        _ => k + 1 < nz,
    }
}

/// Everything the solution of one line reads and writes.
struct Line<'a> {
    rows: &'a [Row],
    xs: &'a Shared,
    cps: &'a Shared,
    dps: &'a Shared,
    off: [isize; 7],
    shape: Shape,
    /// Cells on the line and the flat stride between them.
    n: usize,
    stride: usize,
    /// Stencil slots of the in-line neighbours (`lo` before, `hi` after).
    lo: usize,
    hi: usize,
}

/// Thomas algorithm on the line starting at flat index `base`: off-line neighbours are taken
/// from `x` (cells of the other colour, not written in this pass), the line itself is written.
#[inline(always)]
fn solve_line_impl<const FUSED: bool>(ln: &Line, base: usize) {
    let (nz, ny, nx) = ln.shape;
    let n_all = nz * ny * nx;
    let (rows, xs, cps, dps) = (ln.rows, ln.xs, ln.cps, ln.dps);
    let (mut cprev, mut dprev) = (0.0f32, 0.0f32);
    for m in 0..ln.n {
        let idx = base + m * ln.stride;
        let row = &rows[idx];
        let mut r = row[RHS];
        for (o, (&c, &of)) in row.iter().zip(&ln.off).enumerate().take(7).skip(1) {
            if o == ln.lo || o == ln.hi {
                continue;
            }
            if c != 0.0 {
                let q = idx as isize + of;
                // A non-zero coefficient must point to a cell inside the grid: the flat
                // offset of an out-of-grid neighbour would wrap into another row or plane.
                debug_assert!(
                    q >= 0 && (q as usize) < n_all && in_grid(idx, o, ln.shape),
                    "stencil coefficient {o} at flat index {idx} points outside the grid"
                );
                if q >= 0 && (q as usize) < n_all {
                    // SAFETY: q lies on a line of the other colour, not written in this pass.
                    r = fmadd::<FUSED>(-c, unsafe { xs.get(q as usize) }, r);
                }
            }
        }
        let a = if m > 0 { row[ln.lo] } else { 0.0 };
        let bb = row[0];
        let cc = if m + 1 < ln.n { row[ln.hi] } else { 0.0 };
        let den = fmadd::<FUSED>(-a, cprev, bb);
        let cpv = cc / den;
        let dpv = fmadd::<FUSED>(-a, dprev, r) / den;
        // SAFETY: cells of this line are touched by this thread only.
        unsafe {
            cps.set(idx, cpv);
            dps.set(idx, dpv);
        }
        cprev = cpv;
        dprev = dpv;
    }
    let mut xn = 0.0f32;
    for m in (0..ln.n).rev() {
        let idx = base + m * ln.stride;
        // SAFETY: as above, this line belongs to this thread.
        unsafe {
            let v = fmadd::<FUSED>(-cps.get(idx), xn, dps.get(idx));
            xs.set(idx, v);
            xn = v;
        }
    }
}

/// One line, hot kernel: fused multiply-add in the x86-64 AVX2+FMA branch (chosen at run
/// time), plain multiply and add in the base branch and on other architectures.
#[cfg(all(target_arch = "x86_64", not(feature = "base_only")))]
#[multiversion::multiversion(targets("x86_64+avx2+fma"))]
fn solve_line(ln: &Line, base: usize) {
    multiversion::target::match_target! {
        "x86_64+avx2+fma" => solve_line_impl::<true>(ln, base),
        _ => solve_line_impl::<false>(ln, base),
    }
}

/// One line, base code (no dispatch in this build).
#[cfg(not(all(target_arch = "x86_64", not(feature = "base_only"))))]
fn solve_line(ln: &Line, base: usize) {
    solve_line_impl::<false>(ln, base)
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
    let (n, stride, nl, d1) = match dir {
        0 => (nx, 1usize, ny * nz, ny),
        1 => (ny, nx, nx * nz, nx),
        _ => (nz, nx * ny, nx * ny, nx),
    };
    let xs = Shared::new(x);
    let cps = Shared::new(&mut sc.cp);
    let dps = Shared::new(&mut sc.dp);
    let ln = Line {
        rows,
        xs: &xs,
        cps: &cps,
        dps: &dps,
        off: offsets(shape),
        shape,
        n,
        stride,
        lo: 1 + 2 * dir,
        hi: 2 + 2 * dir,
    };
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
        solve_line(&ln, base);
    });
}

/// Flat offsets of the stencil neighbours, slot 0 is the centre.
fn offsets((_, ny, nx): Shape) -> [isize; 7] {
    [
        0,
        -1,
        1,
        -(nx as isize),
        nx as isize,
        -((nx * ny) as isize),
        (nx * ny) as isize,
    ]
}

/// Zebra sweeps over the directions `dirs` in order (parity 0 then 1 for each).
pub fn sweep(rows: &[Row], x: &mut [f32], sc: &mut Scratch, shape: Shape, dirs: &[usize]) {
    for &d in dirs {
        for par in 0..2 {
            sweep_dir(rows, x, sc, shape, d, par);
        }
    }
}

/// Cells per task of the point-wise residual.
const RESID_CHUNK: usize = 1024;

/// Residual of the cells `start..start + r.len()`, `r = b - C x`.
#[inline(always)]
fn resid_chunk_impl<const FUSED: bool>(
    rows: &[Row],
    x: &[f32],
    n: usize,
    off: &[isize; 7],
    start: usize,
    r: &mut [f32],
) {
    for (di, ri) in r.iter_mut().enumerate() {
        let idx = start + di;
        let row = &rows[idx];
        let mut s = 0.0f32;
        for (o, &of) in off.iter().enumerate() {
            let c = row[o];
            if c != 0.0 {
                let q = idx as isize + of;
                if q >= 0 && (q as usize) < n {
                    s = fmadd::<FUSED>(c, x[q as usize], s);
                }
            }
        }
        *ri = row[RHS] - s;
    }
}

/// Residual of one chunk, hot kernel (fused multiply-add in the AVX2+FMA branch).
#[cfg(all(target_arch = "x86_64", not(feature = "base_only")))]
#[multiversion::multiversion(targets("x86_64+avx2+fma"))]
fn resid_chunk(rows: &[Row], x: &[f32], n: usize, off: &[isize; 7], start: usize, r: &mut [f32]) {
    multiversion::target::match_target! {
        "x86_64+avx2+fma" => resid_chunk_impl::<true>(rows, x, n, off, start, r),
        _ => resid_chunk_impl::<false>(rows, x, n, off, start, r),
    }
}

/// Residual of one chunk, base code (no dispatch in this build).
#[cfg(not(all(target_arch = "x86_64", not(feature = "base_only"))))]
fn resid_chunk(rows: &[Row], x: &[f32], n: usize, off: &[isize; 7], start: usize, r: &mut [f32]) {
    resid_chunk_impl::<false>(rows, x, n, off, start, r)
}

/// Residual `r = b - C x`.
pub fn resid(rows: &[Row], x: &[f32], shape: Shape, r: &mut [f32]) {
    let (nz, ny, nx) = shape;
    let n = nz * ny * nx;
    let off = offsets(shape);
    r.par_chunks_mut(RESID_CHUNK)
        .enumerate()
        .for_each(|(c, rc)| resid_chunk(rows, x, n, &off, c * RESID_CHUNK, rc));
}
