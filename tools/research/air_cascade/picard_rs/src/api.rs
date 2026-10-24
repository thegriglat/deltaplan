//! R6: solver API with an explicit thread count.
//!
//! Every call builds its own `rayon::ThreadPool` and runs inside `pool.install`; the global
//! rayon pool is never configured or used for the solve, so concurrent calls with different
//! thread counts are independent. The result does not depend on the thread count.
//!
//! R6 v3: a case without a reference (`sol_*`, `solution`, `history`) is solved as usual,
//! `Solved.dev` is `None`.
//!
//! R6 v2: criterion scale, time budget, stop reason, start from a snapshot (the game's warm
//! start) and finalized snapshots after chosen iterations.
//!
//! Stop reasons, in priority at the same iteration: diverged, converged, max_iters,
//! time_budget. If the stop is not at a residual check, one extra check is made, so
//! `Solved.residuals` always belong to the delivered field at `iters` (before finalize).
//! A snapshot after N iterations is `finalize(10)` on a copy: bit-identical to the final
//! state of a separate run with `max_iters = N`, the main run is unchanged. `Solved.state`
//! is after `finalize`, like `AirPicardJob.state()` of the game (read after the `final`
//! phase). Warm start (`init`): `u, v, w, th, thd, p` from the snapshot, K and all input
//! from the case, `apply_bc` + 4 V-cycles without touching `p`
//! (`air_picard_job.gd:_program("warm")`), checks counted from iteration 0.

use crate::case::{Case, Consts};
use crate::report::{Dev, Timing, deviation};
use crate::solver::{Check, Picard, Residuals, RunLimits, SolveOut};
use crate::state::State;
use anyhow::{Result, bail};
use std::time::{Duration, Instant};

pub use crate::solver::StopReason;

/// Default iteration limit (as the CLI).
pub const DEFAULT_MAX_ITERS: usize = 2000;

/// Options of one [`solve`] call.
#[derive(Clone, Debug)]
pub struct SolveOpts {
    /// Pool threads; `0` = all logical cores (`std::thread::available_parallelism`).
    pub threads: usize,
    /// Iteration limit (the run stops exactly after this iteration).
    pub max_iters: usize,
    /// Multiplier of the three tolerances of the case criterion; `1.0` = as the reference.
    pub tol_scale: f64,
    /// Wall time since the start of the iterations (after the setup); checked after every
    /// iteration: when exhausted, stop after that iteration and deliver the current field.
    pub time_budget: Option<Duration>,
    /// Start from this snapshot (the game's warm start); `None` = cold start.
    pub init: Option<State>,
    /// Strictly ascending iteration numbers after which a finalized snapshot is taken
    /// (numbers above the iterations actually done are not taken).
    pub snapshot_at: Vec<usize>,
}

impl Default for SolveOpts {
    fn default() -> Self {
        Self {
            threads: 0,
            max_iters: DEFAULT_MAX_ITERS,
            tol_scale: 1.0,
            time_budget: None,
            init: None,
            snapshot_at: Vec::new(),
        }
    }
}

/// Result of [`solve`].
pub struct Solved {
    /// Iterations done.
    pub iters: usize,
    /// Why the run stopped.
    pub stop: StopReason,
    /// Residuals of the delivered field at iteration `iters` (before the final projection).
    pub residuals: Residuals,
    /// Residual checks; the last one is at `iters`.
    pub history: Vec<Check>,
    /// The delivered field (after `finalize`), usable as `init` of the next call.
    pub state: State,
    /// Snapshots after the iterations of `snapshot_at`, as if the solver had stopped there.
    pub snapshots: Vec<State>,
    /// Status, iterations, history, phase times of the iterations.
    pub out: SolveOut,
    /// Wall/CPU timing as written to the R2 file.
    pub timing: Timing,
    /// Deviation of the finalized fields from the case reference; `None` for a case without
    /// a reference (R6 v3).
    pub dev: Option<Dev>,
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

/// Prepare (cold or warm start), iterate to the criterion of `case` scaled by `opts.tol_scale`
/// (or to another stop reason), finalize and compare with the case reference (if it has one).
pub fn solve(case: &Case, opts: &SolveOpts) -> Result<Solved> {
    if !(opts.tol_scale.is_finite() && opts.tol_scale > 0.0) {
        bail!("tol_scale must be finite and > 0, got {}", opts.tol_scale);
    }
    if opts.snapshot_at.windows(2).any(|w| w[0] >= w[1]) {
        bail!(
            "snapshot_at must be strictly ascending: {:?}",
            opts.snapshot_at
        );
    }
    let t0 = Instant::now();
    let pl = pool(opts.threads)?;
    let mut crit = case.criterion.clone();
    crit.tol_mom_rms *= opts.tol_scale;
    crit.tol_th_rms *= opts.tol_scale;
    crit.tol_div_rms *= opts.tol_scale;
    let (mut o, dev, setup_s, s) = pl.install(|| -> Result<_> {
        let mut s = Picard::new(Consts::from_case(case)?);
        if let Some(st) = &opts.init {
            s.init_warm(st)?;
            // The game counts checks from the start of a warm run (no graph-capture step).
            crit.pre_steps = 0;
        } else {
            s.init_background();
        }
        let setup_s = t0.elapsed().as_secs_f64();
        let run = RunLimits {
            max_iters: opts.max_iters,
            time_budget: opts.time_budget,
            snapshot_at: &opts.snapshot_at,
        };
        let o = s.solve(&crit, &run);
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
        phase_s: Some(o.phase_s),
    };
    let last = *o.history.last().expect("solve always ends with a check");
    let k = &s.k;
    let state = State::capture(k, &case.name, &case.path, o.iters, &s.f, Some(&last));
    let snapshots = std::mem::take(&mut o.snapshots)
        .iter()
        .map(|r| State::capture(k, &case.name, &case.path, r.it, &r.f, r.res.as_ref()))
        .collect();
    Ok(Solved {
        iters: o.iters,
        stop: o.stop,
        residuals: last.res,
        history: o.history.clone(),
        state,
        snapshots,
        out: o,
        timing,
        dev,
        picard: s,
        pool: pl,
    })
}
