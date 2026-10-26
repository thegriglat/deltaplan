//! R6: solver API with an explicit thread count.
//!
//! Every call builds its own `rayon::ThreadPool` and runs inside `pool.install`; the global
//! rayon pool is never configured or used for the solve, so concurrent calls with different
//! thread counts are independent. The result does not depend on the thread count.
//!
//! W11 (`docs/contracts/rust-wind/solver.md`): `SolveOpts.freeze` (frozen columns, as the game's
//! `K_FREEZE`/`K_RMASK`/`K_FIXROW`) and `SolveOpts.cancel`, stop reasons `AllFrozen` and
//! `Cancelled`. Without them the call is bit-identical to R6 v3.
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
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

pub use crate::solver::StopReason;

/// Default iteration limit (as the CLI).
pub const DEFAULT_MAX_ITERS: usize = 2000;

/// Values of the frozen columns (layout of [`State`], R4 v2: halo arrays `(nzh, nyh, nxh)`).
#[derive(Clone, Debug)]
pub struct FrozenField {
    pub u: Vec<f32>,
    pub v: Vec<f32>,
    pub w: Vec<f32>,
    pub th: Vec<f32>,
    /// `None` = theta'_d of the start field (frozen) / of `late_mean` (nonconv), as the game,
    /// which passes no theta'_d channel.
    pub thd: Option<Vec<f32>>,
}

/// Frozen columns (W11). The frozen columns hold the values of `field` (none: those of the
/// start field after `init`/background, as the game's snapshot) and the iterations do not
/// change them; residuals and the criterion are over the free columns only. `nu`, `nuh` of the
/// frozen columns stay at the start values.
#[derive(Clone, Debug)]
pub struct Freeze {
    /// `ny * nx` columns without halo, row-major in `y` of the case; non-zero = frozen.
    pub mask: Vec<u8>,
    /// Values of the frozen columns; `None` = the start field.
    pub field: Option<FrozenField>,
}

/// Mechanism columns for the unconverged fallback (W11 v3).
#[derive(Clone, Debug)]
pub struct NonConv {
    /// `ny * nx` columns without halo; non-zero = a column of the H/D mechanism.
    pub mask: Vec<u8>,
    /// Values for those columns at the fallback; `None` = the `late_mean` itself.
    pub field: Option<FrozenField>,
}

/// Fallback convergence rules (W11 v3; the game's `omega_fallback`, `late_from`, `nonconv_*`
/// of `air_picard_job.gd`). With `SolveOpts.fallback = None` the call is bit-identical to v2.
///
/// - after `omega_after` iterations without convergence (`0` = off) every column is
///   under-relaxed with `min(1, omega)` (`x <- x_old + w (x - x_old)` for `u, v, w` after the
///   projection and for `nu, nuh` after the closure) from the next iteration on;
/// - from iteration `late_from` the state at every residual check is added to `late_mean`
///   (`0` = not accumulated, unless `nonconv` is given, as in the game);
/// - at `max_iters` without convergence the field becomes `late_mean`, in the `nonconv.mask`
///   columns `nonconv.field` (none: `late_mean`), then `finalize`. Frozen columns (`freeze`)
///   are not restored (as in the game: the mean of their constant field, maybe 1 ulp off). `Solved.residuals`/`history` stay those of the last iterate.
#[derive(Clone, Debug)]
pub struct Fallback {
    pub omega_after: usize,
    pub omega: f32,
    pub late_from: usize,
    pub nonconv: Option<NonConv>,
}

/// Options of one [`solve`] call.
#[derive(Clone, Debug)]
pub struct SolveOpts {
    /// Pool threads; `0` = all logical cores (`std::thread::available_parallelism`).
    pub threads: usize,
    /// Iteration limit in the game's count (without the cold-start `pre_steps`): the run stops
    /// at the nearest check from above: after iteration `pre_steps + ceil(max_iters / check_every)
    /// * check_every` (`Solved.iters` is the raw count).
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
    /// W11: frozen columns; `None` (or an all-zero mask) = the plain iteration.
    pub freeze: Option<Freeze>,
    /// W11: set to `true` (from any thread) to stop; checked after every iteration and before
    /// the start. The run ends no later than the end of the current iteration with
    /// [`StopReason::Cancelled`] and delivers the current field (finalized).
    pub cancel: Option<Arc<AtomicBool>>,
    /// W11 v3: fallback convergence rules; `None` = bit-identical to v2.
    pub fallback: Option<Fallback>,
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
            freeze: None,
            cancel: None,
            fallback: None,
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
    /// W11 v3: the omega rollback switched on.
    pub omega_fallback_used: bool,
    /// W11 v3: the field was replaced by `late_mean` at `max_iters`.
    pub nonconv_fallback: bool,
    /// W11 v3: fraction of the `nonconv` mechanism columns (0 without a mask).
    pub nonconv_frac: f32,
    /// Solver with the final fields (`picard.f`), after `finalize`.
    pub picard: Picard,
    /// The pool of this call (for further work on `picard` with the same threads).
    pub pool: rayon::ThreadPool,
}

fn cancelled(opts: &SolveOpts) -> bool {
    opts.cancel
        .as_ref()
        .is_some_and(|c| c.load(std::sync::atomic::Ordering::Relaxed))
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
        // W11 v6: the multigrid build, the start projections and `finalize` test the flag.
        let mut s = Picard::new_cancel(Consts::from_case(case)?, opts.cancel.as_ref());
        s.prep_cancel = true;
        if let Some(fr) = &opts.freeze {
            // Validate before the (long) start; the columns are declared after it.
            Picard::new_check_freeze(&s.k, fr)?;
        }
        if let Some(fb) = &opts.fallback {
            s.set_fallback(fb)?;
        }
        if let Some(st) = &opts.init {
            s.init_warm(st)?;
            // The game counts checks from the start of a warm run (no graph-capture step).
            crit.pre_steps = 0;
        } else if !cancelled(opts) || opts.freeze.as_ref().is_some_and(|f| f.field.is_none()) {
            // Cancelled before the start: still the background when the frozen field is the
            // start field (an `AllFrozen` answer must not be zeros).
            s.init_background();
        }
        if let Some(fr) = &opts.freeze {
            s.set_freeze(&fr.mask, fr.field.as_ref())?;
        }
        let setup_s = t0.elapsed().as_secs_f64();
        s.prep_cancel = false;
        // W11 v6: the start was cut short by the flag - the answer is `Cancelled` also when
        // nothing is left to iterate (`AllFrozen`).
        let setup_cut = std::mem::take(&mut s.prep_cut);
        let run = RunLimits {
            max_iters: opts.max_iters,
            time_budget: opts.time_budget,
            snapshot_at: &opts.snapshot_at,
        };
        let mut o = s.solve(&crit, &run);
        // After a cancel in the middle of the iterations the delivered field is the finalized
        // one (bit for bit the field of a run limited to that many iterations); in the other
        // cases (also a cancel before the first iteration) `finalize` tests the flag.
        s.prep_cancel = !(o.stop == StopReason::Cancelled && o.iters > 0);
        s.prep_cut = false;
        s.finalize(10);
        if s.prep_cut || setup_cut {
            o.stop = StopReason::Cancelled;
            o.status = o.stop.status();
        }
        s.prep_cancel = false;
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
        omega_fallback_used: o.omega_fallback_used,
        nonconv_fallback: o.nonconv_fallback,
        nonconv_frac: o.nonconv_frac,
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
