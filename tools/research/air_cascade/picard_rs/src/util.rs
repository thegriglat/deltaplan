//! Small deterministic helpers: chunked parallel reductions and a shared-write pointer.

use rayon::prelude::*;

/// One row of a 7-point stencil: `[C0 centre, C1 -x, C2 +x, C3 -y, C4 +y, C5 -z, C6 +z, b]`.
pub type Row = [f32; 8];

/// Index of the right-hand side inside a [`Row`].
pub const RHS: usize = 7;

const CHUNK: usize = 4096;

/// Sum of `f(i)` for `i in 0..n` in `f64`; the result does not depend on the thread count
/// (fixed chunks, combined in order).
pub fn det_sum<F: Fn(usize) -> f64 + Sync>(n: usize, f: F) -> f64 {
    let parts: Vec<f64> = (0..n.div_ceil(CHUNK))
        .into_par_iter()
        .map(|c| (c * CHUNK..((c + 1) * CHUNK).min(n)).map(&f).sum::<f64>())
        .collect();
    parts.iter().sum()
}

/// Maximum of `f(i)` for `i in 0..n` (0 for empty ranges; NaN propagates as NaN).
pub fn par_max<F: Fn(usize) -> f64 + Sync>(n: usize, f: F) -> f64 {
    let parts: Vec<f64> = (0..n.div_ceil(CHUNK))
        .into_par_iter()
        .map(|c| {
            (c * CHUNK..((c + 1) * CHUNK).min(n))
                .map(&f)
                .fold(0.0, |a: f64, b| {
                    if b.is_nan() || a.is_nan() {
                        f64::NAN
                    } else {
                        a.max(b)
                    }
                })
        })
        .collect();
    parts.iter().fold(0.0, |a, &b| {
        if b.is_nan() || a.is_nan() {
            f64::NAN
        } else {
            a.max(b)
        }
    })
}

/// Raw pointer into a slice that several threads write at disjoint indices.
///
/// Used only by the zebra line sweeps, where lines of one colour touch disjoint cells and
/// read cells of the other colour only.
pub struct Shared {
    ptr: *mut f32,
    len: usize,
}

// SAFETY: callers guarantee disjoint writes and no read of a cell another thread writes.
unsafe impl Send for Shared {}
// SAFETY: see above.
unsafe impl Sync for Shared {}

impl Shared {
    /// Wraps a mutable slice.
    pub fn new(s: &mut [f32]) -> Self {
        Self {
            ptr: s.as_mut_ptr(),
            len: s.len(),
        }
    }

    /// Reads element `i`.
    ///
    /// # Safety
    /// No other thread may write element `i` concurrently.
    #[inline(always)]
    pub unsafe fn get(&self, i: usize) -> f32 {
        debug_assert!(i < self.len);
        unsafe { *self.ptr.add(i) }
    }

    /// Writes element `i`.
    ///
    /// # Safety
    /// No other thread may read or write element `i` concurrently.
    #[inline(always)]
    pub unsafe fn set(&self, i: usize, v: f32) {
        debug_assert!(i < self.len);
        unsafe { *self.ptr.add(i) = v }
    }
}

/// Name of the code branch the runtime dispatch selects for the hot kernels on this CPU
/// (`"x86_64+avx2+fma"` or `"base"`); the same dispatcher as the kernels use.
#[cfg(all(target_arch = "x86_64", not(feature = "base_only")))]
#[multiversion::multiversion(targets("x86_64+avx2+fma"))]
pub fn isa_branch() -> &'static str {
    multiversion::target::match_target! {
        "x86_64+avx2+fma" => "x86_64+avx2+fma",
        _ => "base",
    }
}

/// Name of the code branch (no dispatch in this build).
#[cfg(not(all(target_arch = "x86_64", not(feature = "base_only"))))]
pub fn isa_branch() -> &'static str {
    "base"
}

/// `a * b + c`: one fused multiply-add when `FUSED` (instantiated only inside the AVX2+FMA
/// branch of a multiversioned function, where it is a single instruction), else a plain
/// multiply and add with two roundings, as in the reference.
#[inline(always)]
pub fn fmadd<const FUSED: bool>(a: f32, b: f32, c: f32) -> f32 {
    if FUSED { a.mul_add(b, c) } else { a * b + c }
}
