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
