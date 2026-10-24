//! R6: solver API with an explicit thread count.
//!
//! Every call builds its own `rayon::ThreadPool` and runs inside `pool.install`; the global
//! rayon pool is never configured or used for the solve, so concurrent calls with different
//! thread counts are independent. The result does not depend on the thread count.

use crate::case::{Case, Consts};
use crate::report::{Dev, Timing, deviation};
use crate::solver::{Picard, SolveOut};
use anyhow::Result;
use std::time::Instant;

/// Default iteration limit (as the CLI).
pub const DEFAULT_MAX_ITERS: usize = 2000;

/// Options of one [`solve`] call.
#[derive(Clone, Debug)]
pub struct SolveOpts {
    /// Pool threads; `0` = all logical cores (`std::thread::available_parallelism`).
    pub threads: usize,
    /// Iteration limit.
    pub max_iters: usize,
}

impl Default for SolveOpts {
    fn default() -> Self {
        Self {
            threads: 0,
            max_iters: DEFAULT_MAX_ITERS,
        }
    }
}

/// Result of [`solve`].
pub struct Solved {
    /// Status, iterations, history, phase times of the iterations.
    pub out: SolveOut,
    /// Wall/CPU timing as written to the R2 file.
    pub timing: Timing,
    /// Deviation of the finalized fields from the case reference.
    pub dev: Dev,
    /// Solver with the final fields (`picard.f`), after `finalize`.
    pub picard: Picard,
    /// The pool of this call (for further work on `picard` with the same threads).
    pub pool: rayon::ThreadPool,
}

/// Resolve the thread count: `0` = all logical cores.
pub fn resolve_threads(threads: usize) -> usize {
    if threads == 0 {
        std::thread::available_parallelism().map_or(1, |n| n.get())
    } else {
        threads
    }
}

/// Build a private pool of `threads` (`0` = all logical cores).
pub fn pool(threads: usize) -> Result<rayon::ThreadPool> {
    Ok(rayon::ThreadPoolBuilder::new()
        .num_threads(resolve_threads(threads))
        .build()?)
}

/// User+system CPU seconds of this process (Linux `/proc/self/stat`, 100 ticks/s; 0 elsewhere).
pub fn cpu_seconds() -> f64 {
    std::fs::read_to_string("/proc/self/stat")
        .ok()
        .and_then(|s| {
            let rest = s.rsplit(')').next()?.to_string();
            let f: Vec<&str> = rest.split_whitespace().collect();
            let (u, k) = (
                f.get(11)?.parse::<f64>().ok()?,
                f.get(12)?.parse::<f64>().ok()?,
            );
            Some((u + k) / 100.0)
        })
        .unwrap_or(0.0)
}

/// Prepare, iterate to the criterion of `case`, finalize and compare with the case reference.
pub fn solve(case: &Case, opts: &SolveOpts) -> Result<Solved> {
    let t0 = Instant::now();
    let pl = pool(opts.threads)?;
    let (o, dev, setup_s, s) = pl.install(|| -> Result<_> {
        let mut s = Picard::new(Consts::from_case(case)?);
        s.init_background();
        let setup_s = t0.elapsed().as_secs_f64();
        let o = s.solve(&case.criterion, opts.max_iters);
        s.finalize(10);
        let dev = deviation(case, &s)?;
        Ok((o, dev, setup_s, s))
    })?;
    let timing = Timing {
        total_s: t0.elapsed().as_secs_f64(),
        setup_s,
        iter_s: o.iter_s,
        iters_run: o.iters,
        check_s: o.check_s,
        n_checks: o.n_checks,
        pool_threads: pl.current_num_threads(),
        cpu_s: cpu_seconds(),
    };
    Ok(Solved {
        out: o,
        timing,
        dev,
        picard: s,
        pool: pl,
    })
}
