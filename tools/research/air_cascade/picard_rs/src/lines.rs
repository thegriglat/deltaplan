//! Zebra line solvers (Thomas algorithm) and residual of a 7-point stencil system
//! `sum_o C_o x[idx + off_o] = b` on a flat `(nz, ny, nx)` array — reference
//! `line_thomas` and `resid7`.

use crate::util::{RHS, Row, Shared, fmadd};
use rayon::prelude::*;

/// Shape `(nz, ny, nx)` of a flat array, index `(k * ny + j) * nx + i`.
pub type Shape = (usize, usize, usize);

/// Marker for the Thomas forward-pass scratch. The forward pass keeps `c'` and `d'` in small
/// per-task buffers (layout `[position along the line][line of the group]`), so no array of
/// the grid size is needed; the type stays because callers own one per level.
pub struct Scratch(());

impl Scratch {
    /// Creates the marker for `n` cells (nothing is allocated).
    pub fn new(_n: usize) -> Self {
        Self(())
    }
}

/// Most lines solved together by one call.
const MAXL: usize = 16;

/// Width (in the first free index `a1`) of the block of neighbouring lines one task takes;
/// only the lines of the pass colour inside the block are solved, so a block holds up to
/// `BLOCK / 2` lines. Blocks are multiples of a 64-byte line of `f32` apart (no false sharing
/// of cache lines between tasks for `x`, `cps`, `dps` of the batch).
const BLOCK: [usize; 3] = [4, 32, 32];

/// Everything the solution of lines along one direction reads and writes.
struct Line<'a> {
    rows: &'a [Row],
    xs: &'a Shared,
    off: [isize; 7],
    /// Cells on a line and the flat stride between them.
    n: usize,
    stride: usize,
    /// Stencil slots of the in-line neighbours (`lo` before, `hi` after).
    lo: usize,
    hi: usize,
    /// Stencil slots of the off-line neighbours: `-a1, +a1, -a2, +a2`.
    slots: [usize; 4],
}

/// Lines solved together: flat index of the first cell of each line and, for lines on the
/// grid boundary, which off-line neighbours exist (`-a1, +a1, -a2, +a2`).
struct Group {
    bases: [usize; MAXL],
    ok: [[bool; 4]; MAXL],
    nl: usize,
}

/// One cell of the Thomas forward pass for every line of the group. `FIRST`/`LAST` mark the
/// ends of the lines (no in-line neighbour before/after), `INTERIOR` means every off-line
/// neighbour of every line exists, so no per-neighbour test is needed. A zero coefficient
/// leaves `r` untouched (select), as in the reference.
#[inline(always)]
#[allow(clippy::too_many_arguments)]
fn fwd_step<const FUSED: bool, const INTERIOR: bool, const FIRST: bool, const LAST: bool>(
    ln: &Line,
    g: &Group,
    m: usize,
    cpm: &mut [f32],
    dpm: &mut [f32],
    cprev: &mut [f32; MAXL],
    dprev: &mut [f32; MAXL],
) {
    let (rows, xs) = (ln.rows, ln.xs);
    let offs = ln.slots.map(|s| ln.off[s]);
    for l in 0..g.nl {
        let idx = g.bases[l] + m * ln.stride;
        let row = &rows[idx];
        let mut r = row[RHS];
        for s in 0..4 {
            let c = row[ln.slots[s]];
            if INTERIOR || g.ok[l][s] {
                let q = (idx as isize + offs[s]) as usize;
                // SAFETY: q is a cell of the other colour (in the grid), not written in this pass.
                let xv = unsafe { xs.get(q) };
                if c != 0.0 {
                    r = fmadd::<FUSED>(-c, xv, r);
                }
            } else {
                debug_assert!(
                    c == 0.0,
                    "stencil coefficient {} at flat index {idx} points outside the grid",
                    ln.slots[s]
                );
            }
        }
        let a = if FIRST { 0.0 } else { row[ln.lo] };
        let bb = row[0];
        let cc = if LAST { 0.0 } else { row[ln.hi] };
        let den = fmadd::<FUSED>(-a, cprev[l], bb);
        let cpv = cc / den;
        let dpv = fmadd::<FUSED>(-a, dprev[l], r) / den;
        cpm[l] = cpv;
        dpm[l] = dpv;
        cprev[l] = cpv;
        dprev[l] = dpv;
    }
}

/// Thomas algorithm on the lines of the group: off-line neighbours are taken from `x` (cells of
/// the other colour, not written in this pass), the lines themselves are written. `cp`, `dp`
/// hold `n * nl` values, `[m * nl + lane]`.
#[inline(always)]
fn solve_group_impl<const FUSED: bool, const INTERIOR: bool>(
    ln: &Line,
    g: &Group,
    cp: &mut [f32],
    dp: &mut [f32],
) {
    let (n, nl) = (ln.n, g.nl);
    let (mut cprev, mut dprev) = ([0.0f32; MAXL], [0.0f32; MAXL]);
    macro_rules! step {
        ($m:expr, $first:literal, $last:literal) => {{
            let m = $m;
            let (cpm, dpm) = (&mut cp[m * nl..(m + 1) * nl], &mut dp[m * nl..(m + 1) * nl]);
            fwd_step::<FUSED, INTERIOR, $first, $last>(ln, g, m, cpm, dpm, &mut cprev, &mut dprev);
        }};
    }
    if n == 1 {
        step!(0, true, true);
    } else {
        step!(0, true, false);
        for m in 1..n - 1 {
            step!(m, false, false);
        }
        step!(n - 1, false, true);
    }
    let mut xn = [0.0f32; MAXL];
    for m in (0..n).rev() {
        let (cpm, dpm) = (&cp[m * nl..(m + 1) * nl], &dp[m * nl..(m + 1) * nl]);
        for l in 0..nl {
            let v = fmadd::<FUSED>(-cpm[l], xn[l], dpm[l]);
            // SAFETY: this line belongs to this task.
            unsafe { ln.xs.set(g.bases[l] + m * ln.stride, v) };
            xn[l] = v;
        }
    }
}

/// Lines of one group, hot kernel: fused multiply-add in the x86-64 AVX2+FMA branch (chosen at
/// run time), plain multiply and add in the base branch and on other architectures.
#[cfg(all(target_arch = "x86_64", not(feature = "base_only")))]
#[multiversion::multiversion(targets("x86_64+avx2+fma"))]
fn solve_group(ln: &Line, g: &Group, interior: bool, cp: &mut [f32], dp: &mut [f32]) {
    multiversion::target::match_target! {
        "x86_64+avx2+fma" => if interior {
            solve_group_impl::<true, true>(ln, g, cp, dp)
        } else {
            solve_group_impl::<true, false>(ln, g, cp, dp)
        },
        _ => if interior {
            solve_group_impl::<false, true>(ln, g, cp, dp)
        } else {
            solve_group_impl::<false, false>(ln, g, cp, dp)
        },
    }
}

/// Lines of one group, base code (no dispatch in this build).
#[cfg(not(all(target_arch = "x86_64", not(feature = "base_only"))))]
fn solve_group(ln: &Line, g: &Group, interior: bool, cp: &mut [f32], dp: &mut [f32]) {
    if interior {
        solve_group_impl::<false, true>(ln, g, cp, dp)
    } else {
        solve_group_impl::<false, false>(ln, g, cp, dp)
    }
}

/// One task: the lines of colour `parity` among `a1` in `a1_lo..a1_hi` of plane `a2`.
/// Lines whose off-line neighbours all exist are solved together, boundary lines one by one.
fn solve_block(
    ln: &Line,
    dims: (usize, usize),
    base_of: impl Fn(usize, usize) -> usize,
    (a1_lo, a1_hi, a2): (usize, usize, usize),
    parity: usize,
    (cp, dp): (&mut [f32], &mut [f32]),
) {
    let (d1, d2) = dims;
    let mut inner = Group {
        bases: [0; MAXL],
        ok: [[true; 4]; MAXL],
        nl: 0,
    };
    let first = a1_lo + ((a1_lo + a2) & 1 != parity) as usize;
    for a1 in (first..a1_hi).step_by(2) {
        let ok = [a1 > 0, a1 + 1 < d1, a2 > 0, a2 + 1 < d2];
        let base = base_of(a1, a2);
        if ok.iter().all(|&b| b) {
            inner.bases[inner.nl] = base;
            inner.nl += 1;
        } else {
            let mut one = Group {
                bases: [0; MAXL],
                ok: [ok; MAXL],
                nl: 1,
            };
            one.bases[0] = base;
            solve_group(ln, &one, false, &mut cp[..ln.n], &mut dp[..ln.n]);
        }
    }
    if inner.nl > 0 {
        let len = ln.n * inner.nl;
        solve_group(ln, &inner, true, &mut cp[..len], &mut dp[..len]);
    }
}

/// One zebra half-sweep: all lines along `dir` (0 x, 1 y, 2 z) of the given `parity`
/// (sum of the two other indices mod 2) are solved exactly, off-line neighbours are
/// taken from the current `x`. Tasks are blocks of neighbouring lines of one colour.
fn sweep_dir(rows: &[Row], x: &mut [f32], shape: Shape, dir: usize, parity: usize) {
    let (nz, ny, nx) = shape;
    let (n, stride, d1, d2, slots) = match dir {
        0 => (nx, 1usize, ny, nz, [3, 4, 5, 6]),
        1 => (ny, nx, nx, nz, [1, 2, 5, 6]),
        _ => (nz, nx * ny, nx, ny, [1, 2, 3, 4]),
    };
    let xs = Shared::new(x);
    let ln = Line {
        rows,
        xs: &xs,
        off: offsets(shape),
        n,
        stride,
        lo: 1 + 2 * dir,
        hi: 2 + 2 * dir,
        slots,
    };
    let width = BLOCK[dir];
    let nblk = d1.div_ceil(width);
    let buf = n * width.div_ceil(2).min(MAXL);
    let base_of = |a1: usize, a2: usize| match dir {
        0 => (a2 * ny + a1) * nx,
        1 => a2 * ny * nx + a1,
        _ => a2 * nx + a1,
    };
    (0..d2 * nblk).into_par_iter().for_each_init(
        || (vec![0.0f32; buf], vec![0.0f32; buf]),
        |(cp, dp), t| {
            let (a2, blk) = (t / nblk, t % nblk);
            let lo = blk * width;
            solve_block(
                &ln,
                (d1, d2),
                base_of,
                (lo, (lo + width).min(d1), a2),
                parity,
                (cp, dp),
            );
        },
    );
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
pub fn sweep(rows: &[Row], x: &mut [f32], _sc: &mut Scratch, shape: Shape, dirs: &[usize]) {
    for &d in dirs {
        for par in 0..2 {
            sweep_dir(rows, x, shape, d, par);
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
