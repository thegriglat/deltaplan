//! R6: `api::solve` with different thread counts, also concurrently from several OS threads.

use picard_rs::api::{self, SolveOpts, Solved};
use picard_rs::case::Case;
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
            max_iters: 2000,
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
                            max_iters: 2000,
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
        },
    )
    .unwrap();
    assert!(r.out.iters >= 5, "ran at least max_iters");
    assert_eq!(
        r.out.status, "max",
        "stopped by the limit, not the criterion"
    );
}
