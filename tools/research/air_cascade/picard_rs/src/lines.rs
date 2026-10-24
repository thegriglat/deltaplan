//! Zebra line solvers (Thomas algorithm) and residual of a 7-point stencil system
//! `sum_o C_o x[idx + off_o] = b` on a flat `(nz, ny, nx)` array — reference
//! `line_thomas` and `resid7`.

use crate::kernels::Pos;
use crate::util::{RHS, Row, fmadd};
use rayon::prelude::*;
use std::cell::RefCell;

/// Shape `(nz, ny, nx)` of a flat array, index `(k * ny + j) * nx + i`.
pub type Shape = (usize, usize, usize);

/// Stencil rows (`[f32; 8]`, 32 bytes) stored so that every row lies inside one 64-byte cache
/// line. A large `Vec<Row>` starts 16 bytes after a page boundary, so every second row straddles
/// two cache lines and a row access touches two lines; here the storage is a `Vec<f32>` and the
/// rows start at the first 64-byte boundary inside it. Dereferences to `[Row]`.
pub struct RowBuf {
    data: Vec<f32>,
    off: usize,
    n: usize,
}

impl RowBuf {
    /// `n` zero rows.
    pub fn zeros(n: usize) -> Self {
        // 15 spare floats cover the largest shift to the next 64-byte boundary.
        let data = vec![0.0f32; 8 * n + 16];
        let off = ((64 - data.as_ptr() as usize % 64) % 64) / 4;
        Self { data, off, n }
    }
}

impl From<Vec<Row>> for RowBuf {
    /// Copies the rows into aligned storage.
    fn from(rows: Vec<Row>) -> Self {
        let mut b = Self::zeros(rows.len());
        b.copy_from_slice(&rows);
        b
    }
}

impl std::ops::Deref for RowBuf {
    type Target = [Row];
    fn deref(&self) -> &[Row] {
        self.data[self.off..self.off + 8 * self.n]
            .as_chunks::<8>()
            .0
    }
}

impl std::ops::DerefMut for RowBuf {
    fn deref_mut(&mut self) -> &mut [Row] {
        self.data[self.off..self.off + 8 * self.n]
            .as_chunks_mut::<8>()
            .0
    }
}

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
const MAXL: usize = 64;

/// Width (in the first free index `a1`) of the block of neighbouring lines one task takes;
/// only the lines of the pass colour inside the block are solved, so a block holds up to
/// `BLOCK / 2` lines. Blocks are multiples of a 64-byte line of `f32` apart (no false sharing
/// of cache lines between tasks for `x`, `cps`, `dps` of the batch).
const BLOCK: [usize; 3] = [16, 128, 128];

/// Raw view of the solution array that the tasks of one sweep write at disjoint cells (the lines
/// of one colour) and read at cells of the other colour only. `Copy`, so a task keeps the
/// pointer in a register.
#[derive(Clone, Copy)]
struct Cells {
    ptr: *mut f32,
    len: usize,
}

// SAFETY: tasks write disjoint cells and never read a cell another task writes (zebra colours).
unsafe impl Send for Cells {}
// SAFETY: see above.
unsafe impl Sync for Cells {}

impl Cells {
    fn new(s: &mut [f32]) -> Self {
        Self {
            ptr: s.as_mut_ptr(),
            len: s.len(),
        }
    }

    /// # Safety
    /// No other thread may write element `i` concurrently.
    #[inline(always)]
    unsafe fn get(self, i: usize) -> f32 {
        debug_assert!(i < self.len);
        unsafe { *self.ptr.add(i) }
    }

    /// # Safety
    /// No other thread may read or write element `i` concurrently.
    #[inline(always)]
    unsafe fn set(self, i: usize, v: f32) {
        debug_assert!(i < self.len);
        unsafe { *self.ptr.add(i) = v }
    }
}

/// Everything the solution of lines along one direction reads and writes.
struct Line<'a> {
    rows: &'a [Row],
    xs: Cells,
    /// Flat offsets of the off-line neighbours (`-a1, +a1, -a2, +a2`).
    offs: [isize; 4],
    /// Cells on a line and the flat stride between them.
    n: usize,
    stride: usize,
    /// Direction of the lines: 0 x, 1 y, 2 z.
    dir: usize,
}

/// Stencil slots of the off-line neighbours `-a1, +a1, -a2, +a2` of the lines along `DIR`.
const fn off_slots<const DIR: usize>() -> [usize; 4] {
    match DIR {
        0 => [3, 4, 5, 6],
        1 => [1, 2, 5, 6],
        _ => [1, 2, 3, 4],
    }
}

/// Stencil slots of the in-line neighbours (`lo` before, `hi` after) for lines along `DIR`.
const fn line_slots<const DIR: usize>() -> (usize, usize) {
    (1 + 2 * DIR, 2 + 2 * DIR)
}

/// Lines solved together: flat index of the first cell of each line and, for lines on the
/// grid boundary, which off-line neighbours exist (`-a1, +a1, -a2, +a2`).
struct Group {
    bases: [usize; MAXL],
    ok: [[bool; 4]; MAXL],
    nl: usize,
}

/// Zero values of the "previous" `c'`, `d'` before the first cell of a line.
static ZEROS: [f32; MAXL] = [0.0; MAXL];

/// One cell of the Thomas forward pass for every line of the group. `FIRST`/`LAST` mark the
/// ends of the lines (no in-line neighbour before/after), `INTERIOR` means every off-line
/// neighbour of every line exists, so no per-neighbour test is needed. A zero coefficient
/// leaves `r` untouched (select), as in the reference. `cpm`, `dpm` receive `c'`, `d'` of this
/// cell; `cprev`, `dprev` hold those of the previous cell (zeros for `FIRST`).
#[inline(always)]
fn fwd_step<
    const FUSED: bool,
    const INTERIOR: bool,
    const FIRST: bool,
    const LAST: bool,
    const DIR: usize,
>(
    ln: &Line,
    g: &Group,
    m: usize,
    (cpm, dpm): (&mut [f32], &mut [f32]),
    (cprev, dprev): (&[f32], &[f32]),
) {
    let (rows, xs, offs) = (ln.rows, ln.xs, ln.offs);
    let slots = off_slots::<DIR>();
    let (lo, hi) = line_slots::<DIR>();
    let nl = g.nl;
    let (cpm, dpm, cprev, dprev) = (&mut cpm[..nl], &mut dpm[..nl], &cprev[..nl], &dprev[..nl]);
    for (l, &base) in g.bases[..nl].iter().enumerate() {
        let idx = base + m * ln.stride;
        let row = &rows[idx];
        let mut r = row[RHS];
        for s in 0..4 {
            let c = row[slots[s]];
            if INTERIOR || g.ok[l][s] {
                let q = (idx as isize + offs[s]) as usize;
                // SAFETY: q is a cell of the other colour (in the grid), not written in this pass.
                let xv = unsafe { xs.get(q) };
                // Loaded and computed in any case, selected afterwards: no branch per neighbour.
                if c != 0.0 {
                    r = fmadd::<FUSED>(-c, xv, r);
                }
            } else {
                debug_assert!(
                    c == 0.0,
                    "stencil coefficient {} at flat index {idx} points outside the grid",
                    slots[s]
                );
            }
        }
        let a = if FIRST { 0.0 } else { row[lo] };
        let bb = row[0];
        let cc = if LAST { 0.0 } else { row[hi] };
        let den = fmadd::<FUSED>(-a, cprev[l], bb);
        cpm[l] = cc / den;
        dpm[l] = fmadd::<FUSED>(-a, dprev[l], r) / den;
    }
}

/// Thomas algorithm on the lines of the group: off-line neighbours are taken from `x` (cells of
/// the other colour, not written in this pass), the lines themselves are written. `cp`, `dp`
/// hold `n * nl` values, `[m * nl + lane]`; the back substitution overwrites `dp` with the
/// solution, so the next (already solved) cell is read from there.
#[inline(always)]
fn solve_group_impl<const FUSED: bool, const INTERIOR: bool, const DIR: usize>(
    ln: &Line,
    g: &Group,
    cp: &mut [f32],
    dp: &mut [f32],
) {
    let (n, nl) = (ln.n, g.nl);
    macro_rules! step {
        ($m:expr, $first:literal, $last:literal) => {{
            let m = $m;
            let (cp_lo, cp_hi) = cp.split_at_mut(m * nl);
            let (dp_lo, dp_hi) = dp.split_at_mut(m * nl);
            let prev = if $first {
                (&ZEROS[..], &ZEROS[..])
            } else {
                (&cp_lo[(m - 1) * nl..], &dp_lo[(m - 1) * nl..])
            };
            let cur = (&mut cp_hi[..nl], &mut dp_hi[..nl]);
            fwd_step::<FUSED, INTERIOR, $first, $last, DIR>(ln, g, m, cur, prev);
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

/// Runs `solve_group_impl` for the direction `dir` (0 x, 1 y, 2 z) and interior flag.
macro_rules! dispatch_dir {
    ($fused:literal, $ln:expr, $g:expr, $interior:expr, $cp:expr, $dp:expr, $dir:expr) => {
        match ($dir, $interior) {
            (0, true) => solve_group_impl::<$fused, true, 0>($ln, $g, $cp, $dp),
            (0, false) => solve_group_impl::<$fused, false, 0>($ln, $g, $cp, $dp),
            (1, true) => solve_group_impl::<$fused, true, 1>($ln, $g, $cp, $dp),
            (1, false) => solve_group_impl::<$fused, false, 1>($ln, $g, $cp, $dp),
            (_, true) => solve_group_impl::<$fused, true, 2>($ln, $g, $cp, $dp),
            (_, false) => solve_group_impl::<$fused, false, 2>($ln, $g, $cp, $dp),
        }
    };
}

/// Lines of one group, hot kernel: fused multiply-add in the x86-64 AVX2+FMA branch (chosen at
/// run time), plain multiply and add in the base branch and on other architectures.
#[cfg(all(target_arch = "x86_64", not(feature = "base_only")))]
#[multiversion::multiversion(targets("x86_64+avx2+fma"))]
fn solve_group(ln: &Line, g: &Group, interior: bool, dir: usize, cp: &mut [f32], dp: &mut [f32]) {
    multiversion::target::match_target! {
        "x86_64+avx2+fma" => dispatch_dir!(true, ln, g, interior, cp, dp, dir),
        _ => dispatch_dir!(false, ln, g, interior, cp, dp, dir),
    }
}

/// Lines of one group, base code (no dispatch in this build).
#[cfg(not(all(target_arch = "x86_64", not(feature = "base_only"))))]
fn solve_group(ln: &Line, g: &Group, interior: bool, dir: usize, cp: &mut [f32], dp: &mut [f32]) {
    dispatch_dir!(false, ln, g, interior, cp, dp, dir)
}

/// One task: the lines of colour `parity` among `a1` in `a1_lo..a1_hi` of plane `a2`.
/// Lines whose off-line neighbours all exist are solved together, the lines on the grid
/// boundary (with per-line flags of the neighbours that exist) as a second group.
fn solve_block(
    ln: &Line,
    dims: (usize, usize),
    base_of: impl Fn(usize, usize) -> usize,
    (a1_lo, a1_hi, a2): (usize, usize, usize),
    parity: usize,
    (cp, dp): (&mut [f32], &mut [f32]),
) {
    let (d1, d2) = dims;
    let empty = || Group {
        bases: [0; MAXL],
        ok: [[true; 4]; MAXL],
        nl: 0,
    };
    let (mut inner, mut edge) = (empty(), empty());
    let first = a1_lo + ((a1_lo + a2) & 1 != parity) as usize;
    for a1 in (first..a1_hi).step_by(2) {
        let ok = [a1 > 0, a1 + 1 < d1, a2 > 0, a2 + 1 < d2];
        let base = base_of(a1, a2);
        let g = if ok.iter().all(|&b| b) {
            &mut inner
        } else {
            &mut edge
        };
        g.bases[g.nl] = base;
        g.ok[g.nl] = ok;
        g.nl += 1;
    }
    for (g, interior) in [(&inner, true), (&edge, false)] {
        if g.nl > 0 {
            let len = ln.n * g.nl;
            solve_group(ln, g, interior, ln.dir, &mut cp[..len], &mut dp[..len]);
        }
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
    let xs = Cells::new(x);
    let off = offsets(shape);
    let ln = Line {
        rows,
        xs,
        offs: slots.map(|s| off[s]),
        n,
        stride,
        dir,
    };
    let width = BLOCK[dir];
    let nblk = d1.div_ceil(width);
    let buf = n * width.div_ceil(2).min(MAXL);
    let base_of = |a1: usize, a2: usize| match dir {
        0 => (a2 * ny + a1) * nx,
        1 => a2 * ny * nx + a1,
        _ => a2 * nx + a1,
    };
    (0..d2 * nblk).into_par_iter().for_each(|t| {
        let (a2, blk) = (t / nblk, t % nblk);
        let lo = blk * width;
        WORK.with_borrow_mut(|(cp, dp)| {
            // Fully overwritten by the forward pass before it is read: no clearing needed.
            if cp.len() < buf {
                cp.resize(buf, 0.0);
                dp.resize(buf, 0.0);
            }
            solve_block(
                &ln,
                (d1, d2),
                base_of,
                (lo, (lo + width).min(d1), a2),
                parity,
                (cp, dp),
            );
        });
    });
}

thread_local! {
    /// Per-thread forward-pass buffers `c'`, `d'` (grown on demand, kept between sweeps).
    static WORK: RefCell<(Vec<f32>, Vec<f32>)> = const { RefCell::new((Vec::new(), Vec::new())) };
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

/// Residual `b - C x` of the cell `idx`.
#[inline(always)]
fn resid_at<const FUSED: bool>(
    rows: &[Row],
    x: &[f32],
    n: usize,
    off: &[isize; 7],
    idx: usize,
) -> f32 {
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
    row[RHS] - s
}

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
        *ri = resid_at::<FUSED>(rows, x, n, off, start + di);
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

/// Coarse cells per task of [`restrict_resid`].
const RESTRICT_CHUNK: usize = 1024;

/// Coarse cells `start..` of the restriction of the residual `r = b - C x` (mean of 2x2 columns,
/// times the coarse activity); the coarse solution is zeroed.
#[inline(always)]
fn restrict_resid_chunk_impl<const FUSED: bool>(
    (rows, x, shape): (&[Row], &[f32], Shape),
    off: &[isize; 7],
    act: &[f32],
    start: usize,
    (crows, cx): (&mut [Row], &mut [f32]),
) {
    let (nz, ny, nx) = shape;
    let n = nz * ny * nx;
    let (cny, cnx) = (ny / 2, nx / 2);
    // Coarse coordinates advance with the loop: no integer division per cell.
    let mut pos = Pos::at(start, cnx, cny);
    for (d, (crow, xc)) in crows.iter_mut().zip(cx.iter_mut()).enumerate() {
        let b = (pos.k * ny + 2 * pos.j) * nx + 2 * pos.i;
        pos.advance(cnx, cny);
        // Same order of additions as the restriction of a stored residual.
        let mut s = 0.0f32;
        s += resid_at::<FUSED>(rows, x, n, off, b);
        s += resid_at::<FUSED>(rows, x, n, off, b + 1);
        s += resid_at::<FUSED>(rows, x, n, off, b + nx);
        s += resid_at::<FUSED>(rows, x, n, off, b + nx + 1);
        crow[RHS] = s / 4.0 * act[start + d];
        *xc = 0.0;
    }
}

/// One chunk of [`restrict_resid`], hot kernel (fused multiply-add in the AVX2+FMA branch).
#[cfg(all(target_arch = "x86_64", not(feature = "base_only")))]
#[multiversion::multiversion(targets("x86_64+avx2+fma"))]
fn restrict_resid_chunk(
    fine: (&[Row], &[f32], Shape),
    off: &[isize; 7],
    act: &[f32],
    start: usize,
    out: (&mut [Row], &mut [f32]),
) {
    multiversion::target::match_target! {
        "x86_64+avx2+fma" => restrict_resid_chunk_impl::<true>(fine, off, act, start, out),
        _ => restrict_resid_chunk_impl::<false>(fine, off, act, start, out),
    }
}

/// One chunk of [`restrict_resid`], base code (no dispatch in this build).
#[cfg(not(all(target_arch = "x86_64", not(feature = "base_only"))))]
fn restrict_resid_chunk(
    fine: (&[Row], &[f32], Shape),
    off: &[isize; 7],
    act: &[f32],
    start: usize,
    out: (&mut [Row], &mut [f32]),
) {
    restrict_resid_chunk_impl::<false>(fine, off, act, start, out)
}

/// Residual `r = b - C x` of the fine level `(rows, x, shape)` restricted to the coarse level
/// (mean of 2x2 columns times `act`, the coarse activity) in one pass: the right-hand sides go
/// into `crows` (slot `b`) and the coarse solution `cx` is zeroed. Same values as [`resid`]
/// followed by the restriction of the stored residual, without storing it.
pub fn restrict_resid(
    fine: (&[Row], &[f32], Shape),
    act: &[f32],
    (crows, cx): (&mut [Row], &mut [f32]),
) {
    let off = offsets(fine.2);
    crows
        .par_chunks_mut(RESTRICT_CHUNK)
        .zip(cx.par_chunks_mut(RESTRICT_CHUNK))
        .enumerate()
        .for_each(|(c, out)| restrict_resid_chunk(fine, &off, act, c * RESTRICT_CHUNK, out));
}
