//! R6: `api::solve` with different thread counts, also concurrently from several OS threads.

use picard_rs::api::{self, SolveOpts, Solved, StopReason};
use picard_rs::case::{Case, Consts};
use picard_rs::solver::Picard;
use picard_rs::state::State;
use std::path::PathBuf;

fn case() -> Case {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../../tests/atmosphere/fixtures/air_model/ref/flat_wind.json");
    Case::load(&p).expect("load flat_wind")
}

fn check_same(name: &str, a: &Solved, b: &Solved) {
    assert_eq!(a.out.iters, b.out.iters, "{name}: iterations");
    assert_eq!(a.out.status, b.out.status, "{name}: status");
    for (f, x, y) in [
        ("u", &a.picard.f.u, &b.picard.f.u),
        ("v", &a.picard.f.v, &b.picard.f.v),
        ("w", &a.picard.f.w, &b.picard.f.w),
        ("th", &a.picard.f.th, &b.picard.f.th),
        ("p", &a.picard.f.p, &b.picard.f.p),
    ] {
        // Reductions are deterministic (fixed-size chunks): fields are bit-identical.
        assert_eq!(x.len(), y.len(), "{name}: field {f} length");
        assert!(
            x.iter()
                .zip(y.iter())
                .all(|(p, q)| p.to_bits() == q.to_bits()),
            "{name}: field {f} differs"
        );
    }
}

#[test]
fn threads_resolve() {
    assert!(api::resolve_threads(0) >= 1);
    assert_eq!(api::resolve_threads(3), 3);
    assert_eq!(SolveOpts::default().threads, 0);
}

#[test]
fn concurrent_calls_with_different_threads_agree() {
    let c = case();
    let base = api::solve(
        &c,
        &SolveOpts {
            threads: 1,
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!(base.timing.pool_threads, 1);
    assert!(base.out.iters > 0);
    let counts = [2usize, 3, 4, 0];
    let results: Vec<Solved> = std::thread::scope(|sc| {
        let hs: Vec<_> = counts
            .iter()
            .map(|&t| {
                let c = &c;
                sc.spawn(move || {
                    api::solve(
                        c,
                        &SolveOpts {
                            threads: t,
                            ..SolveOpts::default()
                        },
                    )
                    .unwrap()
                })
            })
            .collect();
        hs.into_iter().map(|h| h.join().unwrap()).collect()
    });
    for (t, r) in counts.iter().zip(&results) {
        assert_eq!(r.timing.pool_threads, api::resolve_threads(*t));
        check_same(&format!("threads {t}"), &base, r);
    }
}

#[test]
fn max_iters_limits() {
    let c = case();
    let r = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            max_iters: 5,
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!(r.iters, 5, "stops exactly after max_iters");
    assert_eq!(r.stop, StopReason::MaxIters);
    assert_eq!(
        r.out.status, "max",
        "stopped by the limit, not the criterion"
    );
    assert_eq!(
        r.history.last().unwrap().it,
        5,
        "residuals of the delivered field"
    );
}

fn bits_eq(x: &[f32], y: &[f32]) -> bool {
    x.len() == y.len() && x.iter().zip(y).all(|(p, q)| p.to_bits() == q.to_bits())
}

fn state_eq(name: &str, a: &State, b: &State) {
    assert_eq!(a.it, b.it, "{name}: it");
    for (f, x, y) in [
        ("u", &a.u, &b.u),
        ("v", &a.v, &b.v),
        ("w", &a.w, &b.w),
        ("th", &a.th, &b.th),
        ("thd", &a.thd, &b.thd),
        ("p", &a.p, &b.p),
    ] {
        assert!(bits_eq(x, y), "{name}: field {f} differs");
    }
    assert!(
        bits_eq(a.nu.as_ref().unwrap(), b.nu.as_ref().unwrap()),
        "{name}: nu"
    );
    assert!(
        bits_eq(a.nuh.as_ref().unwrap(), b.nuh.as_ref().unwrap()),
        "{name}: nuh"
    );
}

/// The v1 driver (blocks of `check_every` after `pre_steps`, finalize) written out with the
/// public pieces: `tol_scale = 1`, cold start of `api::solve` must reproduce it bit for bit.
#[test]
fn cold_start_tol_scale_one_is_bitwise_v1() {
    let c = case();
    let crit = c.criterion.clone();
    let mut s = Picard::new(Consts::from_case(&c).unwrap());
    let pl = api::pool(2).unwrap();
    let iters = pl.install(|| {
        s.init_background();
        let mut it = crit.pre_steps;
        for _ in 0..crit.pre_steps {
            s.outer_step();
        }
        while it < 2000 {
            for _ in 0..crit.check_every {
                s.outer_step();
            }
            it += crit.check_every;
            let r = s.residuals();
            if r.mom_rms < crit.tol_mom_rms
                && r.th_rms < crit.tol_th_rms
                && r.div_rms < crit.tol_div_rms
            {
                break;
            }
        }
        s.finalize(10);
        it
    });
    let r = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            tol_scale: 1.0,
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!(r.iters, iters, "iterations");
    assert_eq!(r.stop, StopReason::Converged);
    for (f, x, y) in [
        ("u", &s.f.u, &r.picard.f.u),
        ("v", &s.f.v, &r.picard.f.v),
        ("w", &s.f.w, &r.picard.f.w),
        ("th", &s.f.th, &r.picard.f.th),
        ("thd", &s.f.thd, &r.picard.f.thd),
        ("p", &s.f.p, &r.picard.f.p),
    ] {
        assert!(bits_eq(x, y), "field {f} differs from the v1 driver");
    }
    assert!(
        bits_eq(&r.state.u, &r.picard.f.u),
        "state is the finalized field"
    );
    assert!(r.history.last().unwrap().it == r.iters);
}

#[test]
fn every_stop_reason_is_reachable() {
    let c = case();
    let conv = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!(conv.stop, StopReason::Converged);
    assert_eq!(conv.out.status, "ok");
    let max = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            max_iters: 7,
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!((max.stop, max.iters), (StopReason::MaxIters, 7));
    // Budget zero: exhausted after the first iteration.
    let tb = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            time_budget: Some(std::time::Duration::ZERO),
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!((tb.stop, tb.iters), (StopReason::TimeBudget, 1));
    assert_eq!(tb.out.status, "max");
    assert_eq!(tb.history.last().unwrap().it, 1, "extra check at the stop");
    assert_eq!(tb.state.it, 1);
    // A generous budget does not cut the run.
    let ok = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            time_budget: Some(std::time::Duration::from_secs(3600)),
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!((ok.stop, ok.iters), (StopReason::Converged, conv.iters));
    // Looser criterion stops earlier; invalid scale and unsorted snapshots are errors.
    let loose = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            tol_scale: 1e3,
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!(loose.stop, StopReason::Converged);
    assert!(loose.iters < conv.iters, "{} < {}", loose.iters, conv.iters);
    assert!(
        api::solve(
            &c,
            &SolveOpts {
                tol_scale: 0.0,
                ..SolveOpts::default()
            }
        )
        .is_err()
    );
    assert!(
        api::solve(
            &c,
            &SolveOpts {
                snapshot_at: vec![5, 5],
                ..SolveOpts::default()
            }
        )
        .is_err()
    );
}

/// A snapshot after N iterations equals the final state of a separate run with `max_iters = N`
/// and the main run is not changed by taking snapshots.
#[test]
fn snapshots_equal_separate_runs_and_do_not_change_the_run() {
    let c = case();
    let plain = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            ..SolveOpts::default()
        },
    )
    .unwrap();
    let at = vec![0, 3, 10, 14, 1_000_000];
    let snap = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            snapshot_at: at.clone(),
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!(snap.iters, plain.iters);
    assert_eq!(
        snap.snapshots.len(),
        4,
        "N above the iterations done is not taken"
    );
    state_eq("main run with snapshots", &plain.state, &snap.state);
    assert!(bits_eq(&plain.picard.f.u, &snap.picard.f.u));
    for (s, &n) in snap.snapshots.iter().zip(&at) {
        let sep = api::solve(
            &c,
            &SolveOpts {
                threads: 3,
                max_iters: n,
                ..SolveOpts::default()
            },
        )
        .unwrap();
        assert_eq!(sep.iters, n);
        state_eq(&format!("snapshot {n}"), &sep.state, s);
        // Check iterations carry their residuals, others none.
        let at_check = snap.history.iter().any(|h| h.it == n);
        assert_eq!(s.residuals.is_some(), at_check, "snapshot {n}: residuals");
    }
}

#[test]
fn warm_start_from_own_state_converges_fast_and_checks_dims() {
    let c = case();
    let cold = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            ..SolveOpts::default()
        },
    )
    .unwrap();
    let warm = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            init: Some(cold.state.clone()),
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!(warm.stop, StopReason::Converged);
    assert!(
        warm.iters <= c.criterion.check_every,
        "warm iters {}",
        warm.iters
    );
    assert!(warm.dev.u_rel < 1e-3, "u_rel {}", warm.dev.u_rel);
    let mut bad = cold.state.clone();
    bad.dims[0] += 1;
    let e = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            init: Some(bad),
            ..SolveOpts::default()
        },
    );
    assert!(e.is_err(), "dims mismatch is an error");
    let mut bad = cold.state;
    bad.u.pop();
    assert!(
        api::solve(
            &c,
            &SolveOpts {
                threads: 2,
                init: Some(bad),
                ..SolveOpts::default()
            }
        )
        .is_err()
    );
}
