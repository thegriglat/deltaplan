//! W11: frozen columns and cancel in `api::solve` (`docs/contracts/rust-wind/solver.md`).
//!
//! Cases: `flat_wind` (no heating) and `heated_slope` (heating, theta'_d) of the repository
//! fixtures; the Ongudai case (`~/data/air_cascade/ongudai`, 400 m, 38 MB) only in the
//! `#[ignore]`d test at the end (no GPU here: the line-by-line match with the game kernels is
//! described in README.md, "Frozen columns").

use picard_rs::api::{self, Freeze, FrozenField, SolveOpts, Solved, StopReason};
use picard_rs::case::{Case, Consts};
use picard_rs::solver::{Picard, RunLimits};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

fn load(name: &str) -> Case {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/atmosphere/fixtures/air_model/ref")
        .join(format!("{name}.json"));
    Case::load(&p).unwrap_or_else(|e| panic!("load {name}: {e}"))
}

fn bits_eq(x: &[f32], y: &[f32]) -> bool {
    x.len() == y.len() && x.iter().zip(y).all(|(p, q)| p.to_bits() == q.to_bits())
}

/// Residual records of two runs, bit for bit.
fn same_history(name: &str, a: &Solved, b: &Solved) {
    assert_eq!(a.iters, b.iters, "{name}: iters");
    assert_eq!(a.stop, b.stop, "{name}: stop");
    assert_eq!(a.history.len(), b.history.len(), "{name}: checks");
    for (x, y) in a.history.iter().zip(&b.history) {
        let (p, q) = (x.res, y.res);
        for (f, s, t) in [
            ("mom_max", p.mom_max, q.mom_max),
            ("mom_rms", p.mom_rms, q.mom_rms),
            ("th_max", p.th_max, q.th_max),
            ("th_rms", p.th_rms, q.th_rms),
            ("thd_rms", p.thd_rms, q.thd_rms),
            ("div_rms", p.div_rms, q.div_rms),
        ] {
            assert_eq!(s.to_bits(), t.to_bits(), "{name}: it {} {f}", x.it);
        }
    }
}

fn same_state(name: &str, a: &Solved, b: &Solved) {
    for (f, x, y) in [
        ("u", &a.state.u, &b.state.u),
        ("v", &a.state.v, &b.state.v),
        ("w", &a.state.w, &b.state.w),
        ("th", &a.state.th, &b.state.th),
        ("thd", &a.state.thd, &b.state.thd),
        ("p", &a.state.p, &b.state.p),
    ] {
        assert!(bits_eq(x, y), "{name}: state.{f} differs");
    }
    for (f, x, y) in [
        ("nu", &a.picard.f.nu, &b.picard.f.nu),
        ("nuh", &a.picard.f.nuh, &b.picard.f.nuh),
    ] {
        assert!(bits_eq(x, y), "{name}: {f} differs");
    }
}

/// A field that is not the solution: the solved state of the plain run, scaled.
fn mech_field(plain: &Solved) -> FrozenField {
    let sc = |a: &[f32], f: f32| a.iter().map(|&x| x * f).collect::<Vec<f32>>();
    FrozenField {
        u: sc(&plain.state.u, 0.9),
        v: sc(&plain.state.v, 1.1),
        w: sc(&plain.state.w, 0.5),
        th: sc(&plain.state.th, 1.2),
        thd: Some(sc(&plain.state.thd, 0.7)),
    }
}

/// A consistent field: the velocities of the plain solution (divergence-free), `theta'` and
/// `theta'_d` scaled. A scaled velocity field is not divergence-free across the frozen
/// columns and the free ones cannot reach the criterion next to it (as in the game: the
/// mechanism fields it freezes are made compatible) - `mech_field` is for the tests that do
/// not need convergence.
fn consistent_field(plain: &Solved) -> FrozenField {
    let sc = |a: &[f32], f: f32| a.iter().map(|&x| x * f).collect::<Vec<f32>>();
    FrozenField {
        u: plain.state.u.clone(),
        v: plain.state.v.clone(),
        w: plain.state.w.clone(),
        th: sc(&plain.state.th, 1.2),
        thd: Some(sc(&plain.state.thd, 0.7)),
    }
}

/// All five channels of the frozen points of `f` are bitwise the field.
fn check_frozen(
    tag: &str,
    c: &Case,
    mask: &[u8],
    f: &picard_rs::solver::Fields,
    fld: &FrozenField,
) -> usize {
    let (nxh, nyh, nzh) = (c.nxh, c.nyh, c.nzh);
    let mut n = 0;
    // Faces with a boundary condition are re-imposed by every `apply_bc` (also in the game's
    // check after the freeze), frozen or not: not compared.
    let k = Consts::from_case(c).unwrap();
    let skip = |kind: char, t: usize| {
        (kind == 'u' && k.b_u.contains(&t)) || (kind == 'v' && k.b_v.contains(&t))
    };
    for kk in 0..nzh {
        for j in 0..nyh {
            for i in 0..nxh {
                let t = (kk * nyh + j) * nxh + i;
                for (kind, x, y) in [
                    ('u', &f.u, &fld.u),
                    ('v', &f.v, &fld.v),
                    ('w', &f.w, &fld.w),
                    ('c', &f.th, &fld.th),
                    ('c', &f.thd, fld.thd.as_ref().unwrap()),
                ] {
                    if frozen_point(c, mask, kind, i, j) && !skip(kind, t) {
                        n += 1;
                        assert_eq!(x[t].to_bits(), y[t].to_bits(), "{tag}: frozen point");
                    }
                }
            }
        }
    }
    n
}

/// `0` = free; stripe `x` in `[x0, x1)`, or a checkerboard of `b`-column squares.
fn stripe(c: &Case, x0: usize, x1: usize) -> Vec<u8> {
    (0..c.ny * c.nx)
        .map(|q| u8::from((x0..x1).contains(&(q % c.nx))))
        .collect()
}

fn checker(c: &Case, b: usize) -> Vec<u8> {
    (0..c.ny * c.nx)
        .map(|q| u8::from(((q % c.nx) / b + (q / c.nx) / b) % 2 == 1))
        .collect()
}

fn opts(threads: usize, freeze: Option<Freeze>) -> SolveOpts {
    SolveOpts {
        threads,
        freeze,
        ..SolveOpts::default()
    }
}

const CASES: [&str; 2] = ["flat_wind", "heated_slope"];

#[test]
fn no_mask_and_zero_mask_are_bitwise_r6() {
    for name in CASES {
        let c = load(name);
        let base = api::solve(&c, &opts(2, None)).unwrap();
        let zero = api::solve(
            &c,
            &opts(
                2,
                Some(Freeze {
                    mask: vec![0; c.nx * c.ny],
                    field: None,
                }),
            ),
        )
        .unwrap();
        // A mask of zeros with a field: the field is ignored, nothing is frozen.
        let zero_f = api::solve(
            &c,
            &opts(
                2,
                Some(Freeze {
                    mask: vec![0; c.nx * c.ny],
                    field: Some(mech_field(&base)),
                }),
            ),
        )
        .unwrap();
        for (n, r) in [("zero mask", &zero), ("zero mask + field", &zero_f)] {
            let n = format!("{name}: {n}");
            same_history(&n, &base, r);
            same_state(&n, &base, r);
        }
        assert_eq!(base.stop, StopReason::Converged, "{name}");
    }
}

/// Plain `Picard` run with frozen columns without the final projection, so the frozen values
/// can be compared before `finalize` sews the field.
fn run_raw(
    c: &Case,
    mask: &[u8],
    field: Option<&FrozenField>,
    threads: usize,
    max_iters: usize,
) -> (Picard, picard_rs::solver::SolveOut) {
    let pl = api::pool(threads).unwrap();
    pl.install(|| {
        let mut s = Picard::new(Consts::from_case(c).unwrap());
        s.init_background();
        s.set_freeze(mask, field).unwrap();
        let run = RunLimits {
            max_iters,
            time_budget: None,
            snapshot_at: &[],
            progress: None,
        };
        let o = s.solve(&c.criterion, &run);
        (s, o)
    })
}

/// Mask of the halo layout points (kind `u`: face `i` frozen when column `i` or `i-1` is).
fn frozen_point(c: &Case, mask: &[u8], kind: char, i: usize, j: usize) -> bool {
    let col = |i: isize, j: isize| -> bool {
        let (nx, ny) = (c.nx as isize, c.ny as isize);
        (1..=nx).contains(&i)
            && (1..=ny).contains(&j)
            && mask[(j - 1) as usize * c.nx + i as usize - 1] != 0
    };
    let (i, j) = (i as isize, j as isize);
    match kind {
        'u' => col(i, j) || col(i - 1, j),
        'v' => col(i, j) || col(i, j - 1),
        _ => col(i, j),
    }
}

#[test]
fn frozen_columns_keep_the_field_and_the_free_ones_converge() {
    for name in CASES {
        let c = load(name);
        let plain = api::solve(&c, &opts(2, None)).unwrap();
        let fld = consistent_field(&plain);
        for (mname, mask) in [("stripe", stripe(&c, 8, 12)), ("checker", checker(&c, 3))] {
            let tag = format!("{name}/{mname}");
            let (s, o) = run_raw(&c, &mask, Some(&fld), 2, 1500);
            assert_eq!(
                o.stop,
                StopReason::Converged,
                "{tag}: free columns converge"
            );
            // Before finalize all five channels of the frozen points are bitwise the field.
            assert!(check_frozen(&tag, &c, &mask, &s.f, &fld) > 0, "{tag}");
            // The free part is really solved: theta' differs from the field there.
            let diff =
                s.f.th
                    .iter()
                    .zip(&fld.th)
                    .filter(|(a, b)| a.to_bits() != b.to_bits())
                    .count();
            assert!(
                diff > 0 || name == "flat_wind",
                "{tag}: free columns solved"
            );

            // Through the API: converged on the free columns, theta' and theta'_d of the
            // frozen columns stay bitwise (the final projection changes only velocities).
            let r = api::solve(
                &c,
                &opts(
                    2,
                    Some(Freeze {
                        mask: mask.clone(),
                        field: Some(fld.clone()),
                    }),
                ),
            )
            .unwrap();
            assert_eq!(r.stop, StopReason::Converged, "{tag}");
            assert!(r.state.u.iter().chain(&r.state.th).all(|x| x.is_finite()));
            let mut sv = s.f.clone();
            sv.th.clone_from(&r.state.th);
            sv.thd.clone_from(&r.state.thd);
            sv.u.clone_from(&fld.u);
            sv.v.clone_from(&fld.v);
            sv.w.clone_from(&fld.w);
            check_frozen(&tag, &c, &mask, &sv, &fld);
            let cr = &c.criterion;
            let l = r.residuals;
            assert!(
                l.mom_rms < cr.tol_mom_rms && l.th_rms < cr.tol_th_rms,
                "{tag}"
            );
            assert!(l.div_rms < cr.tol_div_rms, "{tag}");
            assert_eq!(r.history.last().unwrap().it, r.iters);
        }
        // The frozen field is the plain solution: the free columns stay at it (the same
        // problem, a different path to it).
        let mask = stripe(&c, 8, 12);
        let r = api::solve(
            &c,
            &opts(
                2,
                Some(Freeze {
                    mask,
                    field: Some(FrozenField {
                        th: plain.state.th.clone(),
                        thd: Some(plain.state.thd.clone()),
                        ..consistent_field(&plain)
                    }),
                }),
            ),
        )
        .unwrap();
        let scale = plain.state.u.iter().fold(0.0f32, |a, &x| a.max(x.abs()));
        let err = r
            .state
            .u
            .iter()
            .zip(&plain.state.u)
            .fold(0.0f32, |a, (x, y)| a.max((x - y).abs()));
        assert!(
            err < 1e-2 * scale,
            "{name}: free columns follow the plain solution: {err} of {scale}"
        );
    }
}

/// T4: the divergence in the criterion is that of the free columns minus its mean, recomputed
/// here from the delivered (pre-finalize) fields independently of the solver's residual code.
#[test]
fn divergence_is_over_free_columns_only() {
    let c = load("heated_slope");
    let plain = api::solve(&c, &opts(2, None)).unwrap();
    let fld = mech_field(&plain);
    let mask = stripe(&c, 4, 9);
    let (mut s, o) = run_raw(&c, &mask, Some(&fld), 2, 60);
    let last = o.history.last().unwrap().res.div_rms;
    let k = &s.k;
    let mut div = vec![0.0f32; k.nx * k.ny * k.nz];
    let pl = api::pool(2).unwrap();
    pl.install(|| Picard::divergence(k, &s.f.u, &s.f.v, &s.f.w, &mut div));
    let (mut sum, mut n) = (0.0f64, 0.0f64);
    let free = |r: usize| mask[(r % k.ny) * k.nx..][..k.nx].to_vec();
    for r in 0..k.nz * k.ny {
        let m = free(r);
        for i in 0..k.nx {
            if m[i] == 0 {
                sum += f64::from(div[r * k.nx + i]);
                n += k.fluid[((r / k.ny + 1) * k.nyh + r % k.ny + 1) * k.nxh + i + 1] as f64;
            }
        }
    }
    let mean = (sum / n) as f32;
    let mut sq = 0.0f64;
    for r in 0..k.nz * k.ny {
        let m = free(r);
        for i in 0..k.nx {
            if m[i] == 0 {
                let fl = k.fluid[((r / k.ny + 1) * k.nyh + r % k.ny + 1) * k.nxh + i + 1];
                sq += f64::from(div[r * k.nx + i] - mean * fl).powi(2);
            }
        }
    }
    let mine = (sq / n).sqrt();
    assert!(
        (mine - last).abs() <= 1e-3 * last.max(1e-12),
        "div_rms {mine:e} vs solver {last:e}"
    );
    // Unmasked (all columns) the same field is far from the criterion: the frozen field is
    // not divergence-free across the stripe, which T4 must not count.
    let mut s2 = s.k.n_fluid;
    s2 += 0.0;
    let all = (div.iter().map(|&d| f64::from(d).powi(2)).sum::<f64>() / s2).sqrt();
    assert!(
        all > 10.0 * last,
        "all-column divergence {all:e} vs free {last:e}"
    );
    let _ = &mut s;
}

#[test]
fn all_frozen_is_the_frozen_field() {
    for name in CASES {
        let c = load(name);
        let plain = api::solve(&c, &opts(2, None)).unwrap();
        let fld = mech_field(&plain);
        let all = vec![1u8; c.nx * c.ny];
        let r = api::solve(
            &c,
            &opts(
                2,
                Some(Freeze {
                    mask: all.clone(),
                    field: Some(fld.clone()),
                }),
            ),
        )
        .unwrap();
        assert_eq!(r.stop, StopReason::AllFrozen, "{name}");
        assert_eq!(r.iters, 0, "{name}");
        assert_eq!(r.out.status, "ok");
        assert_eq!(r.history.last().unwrap().it, 0);
        assert!(bits_eq(&r.state.th, &fld.th), "{name}: th");
        assert!(
            bits_eq(&r.state.thd, fld.thd.as_ref().unwrap()),
            "{name}: thd"
        );
        // Before the sewing projection u, v, w are the field bit for bit.
        let (s, o) = run_raw(&c, &all, Some(&fld), 1, 100);
        assert_eq!((o.stop, o.iters), (StopReason::AllFrozen, 0), "{name}");
        assert!(check_frozen(name, &c, &all, &s.f, &fld) > 0);
        // After finalize (the game's `final`) the velocities are divergence-free sewn field.
        assert!(r.state.u.iter().all(|x| x.is_finite()), "{name}");
        // Without a field: the start field (cold start = background) is kept.
        let r0 = api::solve(
            &c,
            &opts(
                2,
                Some(Freeze {
                    mask: all,
                    field: None,
                }),
            ),
        )
        .unwrap();
        assert_eq!((r0.stop, r0.iters), (StopReason::AllFrozen, 0), "{name}");
        assert!(
            r0.state.th.iter().all(|&x| x == 0.0),
            "{name}: start theta' is 0"
        );
    }
}

#[test]
fn threads_do_not_change_the_result() {
    for name in CASES {
        let c = load(name);
        let plain = api::solve(&c, &opts(2, None)).unwrap();
        let fz = Freeze {
            mask: checker(&c, 4),
            field: Some(mech_field(&plain)),
        };
        let few = |t| SolveOpts {
            max_iters: 40,
            ..opts(t, Some(fz.clone()))
        };
        let a = api::solve(&c, &few(1)).unwrap();
        let b = api::solve(&c, &few(4)).unwrap();
        same_history(name, &a, &b);
        same_state(name, &a, &b);
    }
}

#[test]
fn bad_lengths_are_errors() {
    let c = load("flat_wind");
    let plain = api::solve(&c, &opts(2, None)).unwrap();
    let ok = mech_field(&plain);
    let bad_mask = Freeze {
        mask: vec![1; c.nx * c.ny + 1],
        field: None,
    };
    let e = api::solve(&c, &opts(1, Some(bad_mask)))
        .err()
        .expect("mask length");
    assert!(e.to_string().contains("mask"), "{e}");
    let mut f = ok.clone();
    f.thd.as_mut().unwrap().pop();
    let bad_field = Freeze {
        mask: stripe(&c, 2, 3),
        field: Some(f),
    };
    let e = api::solve(&c, &opts(1, Some(bad_field)))
        .err()
        .expect("field length");
    assert!(e.to_string().contains("thd"), "{e}");
    // An empty mask is a length error too (the game: "freeze_mask не ny·nx").
    let empty = Freeze {
        mask: vec![],
        field: None,
    };
    assert!(api::solve(&c, &opts(1, Some(empty))).is_err());
}

#[test]
fn cancel_before_the_start_and_during_the_run() {
    let c = load("heated_slope");
    // Set before the call: no iterations, a finite field.
    let flag = Arc::new(AtomicBool::new(true));
    let r = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            cancel: Some(flag),
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!((r.stop, r.iters), (StopReason::Cancelled, 0));
    assert_eq!(r.out.status, "max");
    assert!(r.state.u.iter().chain(&r.state.th).all(|x| x.is_finite()));
    assert_eq!(r.history.last().unwrap().it, 0);

    // Set from another thread while iterating (frozen run, so the free part never converges
    // before the flag at this tolerance): it ends at an iteration boundary - the delivered
    // field equals a separate run limited to that many iterations, bit for bit.
    let plain = api::solve(&c, &opts(2, None)).unwrap();
    let fz = Freeze {
        mask: stripe(&c, 8, 12),
        field: Some(mech_field(&plain)),
    };
    let flag = Arc::new(AtomicBool::new(false));
    let f2 = flag.clone();
    let h = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(1500));
        f2.store(true, Ordering::Relaxed);
    });
    let t = std::time::Instant::now();
    let run = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            freeze: Some(fz.clone()),
            cancel: Some(flag),
            tol_scale: 1e-9,
            max_iters: 1_000_000,
            ..SolveOpts::default()
        },
    )
    .unwrap();
    h.join().unwrap();
    assert_eq!(run.stop, StopReason::Cancelled);
    assert!(run.iters > 0 && run.iters < 1_000_000);
    // Latency: the run ended soon after the flag (one iteration + checks + finalize).
    assert!(t.elapsed().as_secs_f64() < 5.0);
    assert!(
        run.state
            .u
            .iter()
            .chain(&run.state.th)
            .all(|x| x.is_finite())
    );
    let sep = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            freeze: Some(fz),
            tol_scale: 1e-9,
            // W11 v5: `max_iters` acts at a check; the snapshot is the state after `run.iters`.
            max_iters: run.iters,
            snapshot_at: vec![run.iters],
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!(sep.stop, StopReason::MaxIters);
    let snap = &sep.snapshots[0];
    for (f, x, y) in [
        ("u", &run.state.u, &snap.u),
        ("v", &run.state.v, &snap.v),
        ("w", &run.state.w, &snap.w),
        ("th", &run.state.th, &snap.th),
        ("thd", &run.state.thd, &snap.thd),
        ("p", &run.state.p, &snap.p),
    ] {
        assert!(bits_eq(x, y), "cancel vs max_iters: {f} differs");
    }
}

/// Long: the 400 m Ongudai case (38 MB), a stripe frozen with the field of the same case's
/// plain run, few iterations. Run with `cargo test --release -p picard_rs --test freeze --
/// --ignored`.
#[test]
#[ignore = "400 m Ongudai case from ~/data, release only"]
fn ongudai_stripe_few_iterations() {
    let p = PathBuf::from(std::env::var("HOME").unwrap())
        .join("data/air_cascade/ongudai/ongudai_d400_u3_heat.json");
    if !p.exists() {
        eprintln!("no Ongudai case, skipped");
        return;
    }
    let c = Case::load(&p).unwrap();
    let few = |freeze| SolveOpts {
        threads: 4,
        max_iters: 30,
        freeze,
        ..SolveOpts::default()
    };
    let plain = api::solve(&c, &few(None)).unwrap();
    let mask = stripe(&c, c.nx / 3, c.nx / 2);
    let fz = Freeze {
        mask: mask.clone(),
        field: Some(mech_field(&plain)),
    };
    let a = api::solve(&c, &few(Some(fz.clone()))).unwrap();
    let b = api::solve(
        &c,
        &SolveOpts {
            threads: 1,
            ..few(Some(fz))
        },
    )
    .unwrap();
    same_history("ongudai threads", &a, &b);
    same_state("ongudai threads", &a, &b);
    let z = api::solve(
        &c,
        &few(Some(Freeze {
            mask: vec![0; c.nx * c.ny],
            field: None,
        })),
    )
    .unwrap();
    same_history("ongudai zero mask", &plain, &z);
    same_state("ongudai zero mask", &plain, &z);
}

/// W11 v5: `FrozenField.thd = None` - theta'_d of the frozen columns is that of the start field
/// (the game passes no such channel); a cold start has theta'_d = 0, so `None` is `Some(zeros)`.
#[test]
fn missing_thd_is_the_start_thd() {
    let c = load("heated_slope");
    let plain = api::solve(&c, &opts(2, None)).unwrap();
    let mut f = mech_field(&plain);
    let mask = stripe(&c, 2, 5);
    let run = |f: FrozenField| {
        api::solve(
            &c,
            &opts(
                2,
                Some(Freeze {
                    mask: mask.clone(),
                    field: Some(f),
                }),
            ),
        )
        .unwrap()
    };
    let n = f.thd.as_ref().unwrap().len();
    let some = run(FrozenField {
        thd: Some(vec![0.0; n]),
        ..f.clone()
    });
    f.thd = None;
    let none = run(f);
    same_history("thd none", &some, &none);
    same_state("thd none", &some, &none);
}
