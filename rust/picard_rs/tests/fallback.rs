//! W11 v3: fallback convergence rules in `api::solve` (`docs/contracts/rust-wind/solver.md`,
//! the game's `air_picard_job.gd`: `omega_fallback`, `late_from`, `nonconv_*`).
//!
//! Cases: `flat_wind` and `heated_slope` of the repository fixtures. The Ongudai tests (400 m,
//! 38 MB, `~/data/air_cascade/ongudai`) are `#[ignore]`d: run them with
//! `cargo test --release -p picard_rs --test fallback -- --ignored --nocapture`.

use picard_rs::api::{self, Fallback, Freeze, FrozenField, NonConv, SolveOpts, Solved, StopReason};
use picard_rs::case::{Case, Consts};
use picard_rs::solver::Picard;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

fn load(name: &str) -> Case {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/atmosphere/fixtures/air_model/ref")
        .join(format!("{name}.json"));
    Case::load(&p).unwrap_or_else(|e| panic!("load {name}: {e}"))
}

fn bits_eq(x: &[f32], y: &[f32]) -> bool {
    x.len() == y.len() && x.iter().zip(y).all(|(p, q)| p.to_bits() == q.to_bits())
}

fn same_history(name: &str, a: &Solved, b: &Solved) {
    assert_eq!(a.iters, b.iters, "{name}: iters");
    assert_eq!(a.stop, b.stop, "{name}: stop");
    assert_eq!(a.history.len(), b.history.len(), "{name}: checks");
    for (x, y) in a.history.iter().zip(&b.history) {
        let (p, q) = (x.res, y.res);
        for (f, s, t) in [
            ("mom_max", p.mom_max, q.mom_max),
            ("mom_rms", p.mom_rms, q.mom_rms),
            ("th_rms", p.th_rms, q.th_rms),
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
        ("nu", &a.picard.f.nu, &b.picard.f.nu),
        ("nuh", &a.picard.f.nuh, &b.picard.f.nuh),
    ] {
        assert!(bits_eq(x, y), "{name}: {f} differs");
    }
}

fn scaled(s: &Solved, (u, v, w, th, thd): (f32, f32, f32, f32, f32)) -> FrozenField {
    let sc = |a: &[f32], f: f32| a.iter().map(|&x| x * f).collect::<Vec<f32>>();
    FrozenField {
        u: sc(&s.state.u, u),
        v: sc(&s.state.v, v),
        w: sc(&s.state.w, w),
        th: sc(&s.state.th, th),
        thd: Some(sc(&s.state.thd, thd)),
    }
}

fn stripe(c: &Case, x0: usize, x1: usize) -> Vec<u8> {
    (0..c.ny * c.nx)
        .map(|q| u8::from((x0..x1).contains(&(q % c.nx))))
        .collect()
}

/// A mask column `(i, j)` of the interior (0-based) is set.
fn in_mask(c: &Case, mask: &[u8], i: i64, j: i64) -> bool {
    i >= 0
        && j >= 0
        && (i as usize) < c.nx
        && (j as usize) < c.ny
        && mask[j as usize * c.nx + i as usize] != 0
}

/// Point `(i, j)` (halo indexes) of kind `u`/`v`/centre is in the mask (`frozen_at`).
fn masked(c: &Case, mask: &[u8], kind: char, i: usize, j: usize) -> bool {
    let (i, j) = (i as i64 - 1, j as i64 - 1);
    let own = in_mask(c, mask, i, j);
    match kind {
        'u' => own || in_mask(c, mask, i - 1, j),
        'v' => own || in_mask(c, mask, i, j - 1),
        _ => own,
    }
}

fn base(threads: usize) -> SolveOpts {
    SolveOpts {
        threads,
        ..SolveOpts::default()
    }
}

fn fb(omega_after: usize, omega: f32, late_from: usize, nonconv: Option<NonConv>) -> Fallback {
    Fallback {
        omega_after,
        omega,
        late_from,
        nonconv,
    }
}

/// Iterations of a never-converging run that end exactly at a residual check.
fn max_at_check(c: &Case, n_checks: usize) -> usize {
    c.criterion.pre_steps + n_checks * c.criterion.check_every
}

#[test]
fn none_and_inert_fallback_are_bitwise_v2() {
    for name in ["flat_wind", "heated_slope"] {
        let c = load(name);
        let plain = api::solve(&c, &base(2)).unwrap();
        assert_eq!(plain.stop, StopReason::Converged, "{name}");
        assert!(!plain.omega_fallback_used && !plain.nonconv_fallback);
        assert_eq!(plain.nonconv_frac, 0.0);
        // Rules that never fire: omega_after / late_from beyond the run, no mask.
        let inert = api::solve(
            &c,
            &SolveOpts {
                fallback: Some(fb(100_000, 0.5, 0, None)),
                ..base(2)
            },
        )
        .unwrap();
        same_history(name, &plain, &inert);
        same_state(name, &plain, &inert);
        assert!(!inert.omega_fallback_used && !inert.nonconv_fallback);
        // Late mean accumulated but the run converges: the field is not replaced.
        let late = api::solve(
            &c,
            &SolveOpts {
                fallback: Some(fb(0, 0.5, 20, None)),
                ..base(2)
            },
        )
        .unwrap();
        same_history(name, &plain, &late);
        same_state(name, &plain, &late);
        assert!(!late.nonconv_fallback);
    }
}

#[test]
fn omega_rollback_switches_after_omega_after() {
    for name in ["flat_wind", "heated_slope"] {
        let c = load(name);
        // The game's iteration count (without `pre_steps`) and the raw one of the same check.
        let sw = 2 * c.criterion.check_every;
        let sw_raw = max_at_check(&c, 2);
        let end = max_at_check(&c, 6);
        let hard = |max_iters, fallback| SolveOpts {
            max_iters: max_iters - c.criterion.pre_steps,
            tol_scale: 1e-9,
            fallback,
            ..base(2)
        };
        let plain = api::solve(&c, &hard(end, None)).unwrap();
        let rolled = api::solve(&c, &hard(end, Some(fb(sw, 0.5, 0, None)))).unwrap();
        assert_eq!(plain.stop, StopReason::MaxIters, "{name}");
        assert!(rolled.omega_fallback_used, "{name}");
        assert!(!rolled.nonconv_fallback && rolled.nonconv_frac == 0.0);
        // Before the switch (checks up to iteration `sw`, the iterations before it) the two
        // runs are the same bit for bit; after it they differ.
        let n_same = plain.history.iter().take_while(|h| h.it <= sw_raw).count();
        assert!(n_same >= 2, "{name}");
        for (x, y) in plain.history.iter().zip(&rolled.history).take(n_same) {
            assert_eq!(x.res.mom_rms.to_bits(), y.res.mom_rms.to_bits(), "{name}");
            assert_eq!(x.res.th_rms.to_bits(), y.res.th_rms.to_bits(), "{name}");
        }
        let last = (
            plain.history.last().unwrap().res,
            rolled.history.last().unwrap().res,
        );
        assert_ne!(last.0.mom_rms.to_bits(), last.1.mom_rms.to_bits(), "{name}");
        // A tiny omega nearly stops the iteration after the switch: the movement of the field
        // is a small part of the unrelaxed one (x <- x_old + w (x - x_old) with w = 1e-4).
        let at_sw = api::solve(&c, &hard(sw_raw, None)).unwrap();
        let slow = api::solve(&c, &hard(end, Some(fb(sw, 1e-4, 0, None)))).unwrap();
        let mv = |a: &Solved| {
            a.state
                .u
                .iter()
                .zip(&at_sw.state.u)
                .map(|(&x, &y)| f64::from((x - y).abs()))
                .fold(0.0f64, f64::max)
        };
        assert!(
            mv(&slow) < 0.05 * mv(&plain),
            "{name}: slow {} plain {}",
            mv(&slow),
            mv(&plain)
        );
        // omega > 1 is capped at 1 (no over-relaxation): omega 7 and 1 agree bit for bit.
        let w7 = api::solve(&c, &hard(end, Some(fb(sw, 7.0, 0, None)))).unwrap();
        let w1 = api::solve(&c, &hard(end, Some(fb(sw, 1.0, 0, None)))).unwrap();
        same_history(name, &w7, &w1);
        same_state(name, &w7, &w1);
    }
}

#[test]
fn late_mean_and_nonconv_at_max_iters() {
    let c = load("heated_slope");
    let ce = c.criterion.check_every;
    let end = max_at_check(&c, 6);
    let late_from = 3 * ce; // the game's count, without `pre_steps`
    let plain = api::solve(&c, &base(2)).unwrap();
    let mask = stripe(&c, c.nx / 3, c.nx / 2);
    let n_mask = mask.iter().filter(|&&m| m != 0).count();
    let field = scaled(&plain, (0.9, 1.1, 0.5, 1.2, 0.7));
    let hard = |threads, nonconv: Option<NonConv>| SolveOpts {
        max_iters: end - c.criterion.pre_steps,
        tol_scale: 1e-9,
        fallback: Some(fb(0, 0.5, late_from, nonconv)),
        ..base(threads)
    };
    let nc = Some(NonConv {
        mask: mask.clone(),
        field: Some(field.clone()),
    });
    let r = api::solve(&c, &hard(2, nc.clone())).unwrap();
    assert_eq!(r.stop, StopReason::MaxIters);
    assert!(r.nonconv_fallback && !r.omega_fallback_used);
    assert_eq!(r.nonconv_frac, n_mask as f32 / (c.nx * c.ny) as f32);
    assert!(r.state.u.iter().all(|x| x.is_finite()));

    // The same, independently: the plain iteration by hand (no rules), the states at the checks
    // from `late_from` (not the last one) summed in f32 in this order, mean = sum * (1/n),
    // the mask columns := field, then finalize(10).
    let mean_run = |nonconv: bool| -> Picard {
        let pl = api::pool(2).unwrap();
        pl.install(|| {
            let mut s = Picard::new(Consts::from_case(&c).unwrap());
            s.init_background();
            let mut sum: Option<[Vec<f32>; 5]> = None;
            let mut n = 0usize;
            for it in 1..=end {
                s.outer_step();
                let check =
                    it > c.criterion.pre_steps && (it - c.criterion.pre_steps).is_multiple_of(ce);
                if check {
                    s.residuals(); // the check's boundary condition pass
                    if it - c.criterion.pre_steps >= late_from && it < end {
                        let f = &s.f;
                        let cur = [&f.u, &f.v, &f.w, &f.th, &f.thd];
                        match sum.as_mut() {
                            None => sum = Some(cur.map(|a| a.clone())),
                            Some(sm) => {
                                for (d, a) in sm.iter_mut().zip(cur) {
                                    d.iter_mut().zip(a).for_each(|(d, &a)| *d += a);
                                }
                            }
                        }
                        n += 1;
                    }
                }
            }
            s.residuals(); // the final check at `end`
            let sm = sum.unwrap();
            assert!(n >= 2);
            let inv = (1.0f64 / n as f64) as f32;
            let f = &mut s.f;
            for (x, m) in [&mut f.u, &mut f.v, &mut f.w, &mut f.th, &mut f.thd]
                .into_iter()
                .zip(&sm)
            {
                x.iter_mut().zip(m).for_each(|(x, &m)| *x = m * inv);
            }
            if nonconv {
                let (nxh, nyh) = (c.nxh, c.nyh);
                for k in 0..c.nzh {
                    for j in 0..nyh {
                        for i in 0..nxh {
                            let t = (k * nyh + j) * nxh + i;
                            for (kind, x, y) in [
                                ('u', &mut f.u, &field.u),
                                ('v', &mut f.v, &field.v),
                                ('w', &mut f.w, &field.w),
                                ('c', &mut f.th, &field.th),
                                ('c', &mut f.thd, field.thd.as_ref().unwrap()),
                            ] {
                                if masked(&c, &mask, kind, i, j) {
                                    x[t] = y[t];
                                }
                            }
                        }
                    }
                }
            }
            s.finalize(10);
            s
        })
    };
    let by_hand = mean_run(true);
    for (f, x, y) in [
        ("u", &r.state.u, &by_hand.f.u),
        ("v", &r.state.v, &by_hand.f.v),
        ("w", &r.state.w, &by_hand.f.w),
        ("th", &r.state.th, &by_hand.f.th),
        ("thd", &r.state.thd, &by_hand.f.thd),
        ("p", &r.state.p, &by_hand.f.p),
    ] {
        assert!(bits_eq(x, y), "by hand: {f} differs");
    }
    // Mask columns hold the mechanism's theta', theta'_d bit for bit (finalize does not
    // touch them); the rest is the mean (differs from the last iterate).
    let (nxh, nyh) = (c.nxh, c.nyh);
    let mut n_in = 0;
    for k in 0..c.nzh {
        for j in 0..nyh {
            for i in 0..nxh {
                if masked(&c, &mask, 'c', i, j) {
                    let t = (k * nyh + j) * nxh + i;
                    n_in += 1;
                    assert_eq!(r.state.th[t].to_bits(), field.th[t].to_bits());
                    assert_eq!(
                        r.state.thd[t].to_bits(),
                        field.thd.as_ref().unwrap()[t].to_bits()
                    );
                }
            }
        }
    }
    assert!(n_in > 0);
    // Without the mechanism field: the mask is only counted, the whole field is the mean.
    let only_mean = api::solve(
        &c,
        &hard(
            2,
            Some(NonConv {
                mask: mask.clone(),
                field: None,
            }),
        ),
    )
    .unwrap();
    assert!(only_mean.nonconv_fallback);
    assert_eq!(only_mean.nonconv_frac, r.nonconv_frac);
    let nomask = api::solve(&c, &hard(2, None)).unwrap();
    assert!(nomask.nonconv_fallback && nomask.nonconv_frac == 0.0);
    same_state("mask without field = no mask", &only_mean, &nomask);
    assert!(!bits_eq(&nomask.state.th, &r.state.th));
    // Not the last iterate: the plain run to `end` differs.
    let last = api::solve(
        &c,
        &SolveOpts {
            max_iters: end - c.criterion.pre_steps,
            tol_scale: 1e-9,
            ..base(2)
        },
    )
    .unwrap();
    assert!(!last.nonconv_fallback);
    assert!(!bits_eq(&last.state.th, &nomask.state.th));
    // The residual records stay those of the last iterate.
    same_history("history", &last, &nomask);

    // Threads: 1 and 4 bit for bit.
    let a = api::solve(&c, &hard(1, nc.clone())).unwrap();
    let b = api::solve(&c, &hard(4, nc)).unwrap();
    same_history("threads", &a, &b);
    same_state("threads", &a, &b);
    same_state("threads vs 2", &a, &r);
    let _ = mean_run;
}

#[test]
fn rollback_late_mean_and_freeze_threads() {
    // All rules together with frozen columns: 1 and 4 threads bit for bit, the frozen columns
    // keep the field through the fallback.
    let c = load("heated_slope");
    let end = max_at_check(&c, 6);
    let plain = api::solve(&c, &base(2)).unwrap();
    let fz = Freeze {
        mask: stripe(&c, 2, 5),
        field: Some(scaled(&plain, (1.0, 1.0, 1.0, 1.2, 0.7))),
    };
    let nc = NonConv {
        mask: stripe(&c, 8, 11),
        field: Some(scaled(&plain, (0.9, 1.1, 0.5, 1.2, 0.7))),
    };
    let run = |t| {
        api::solve(
            &c,
            &SolveOpts {
                max_iters: end - c.criterion.pre_steps,
                tol_scale: 1e-9,
                freeze: Some(fz.clone()),
                fallback: Some(fb(
                    2 * c.criterion.check_every,
                    0.5,
                    3 * c.criterion.check_every,
                    Some(nc.clone()),
                )),
                ..base(t)
            },
        )
        .unwrap()
    };
    let (a, b) = (run(1), run(4));
    assert!(a.omega_fallback_used && a.nonconv_fallback);
    same_history("freeze+fallback", &a, &b);
    same_state("freeze+fallback", &a, &b);
    let fld = fz.field.as_ref().unwrap();
    let (nxh, nyh) = (c.nxh, c.nyh);
    for k in 0..c.nzh {
        for j in 0..nyh {
            for i in 0..nxh {
                if masked(&c, &fz.mask, 'c', i, j) {
                    let t = (k * nyh + j) * nxh + i;
                    // As in the game: not restored after the late mean, the mean of the
                    // constant field (3 states: checks 3, 4, 5), summed in f32 and scaled.
                    let mean = |x: f32| (x + x + x) * ((1.0f64 / 3.0) as f32);
                    assert_eq!(a.state.th[t].to_bits(), mean(fld.th[t]).to_bits());
                    assert_eq!(
                        a.state.thd[t].to_bits(),
                        mean(fld.thd.as_ref().unwrap()[t]).to_bits()
                    );
                }
            }
        }
    }
}

#[test]
fn bad_fallback_is_an_error() {
    let c = load("flat_wind");
    let run = |f: Fallback| {
        api::solve(
            &c,
            &SolveOpts {
                fallback: Some(f),
                ..base(1)
            },
        )
    };
    let e = run(fb(
        10,
        0.5,
        0,
        Some(NonConv {
            mask: vec![0; c.nx * c.ny + 1],
            field: None,
        }),
    ))
    .err()
    .expect("mask length");
    assert!(e.to_string().contains("nonconv.mask"), "{e}");
    let e = run(fb(10, 0.0, 0, None)).err().expect("omega");
    assert!(e.to_string().contains("omega"), "{e}");
    let plain = api::solve(&c, &base(1)).unwrap();
    let mut f = scaled(&plain, (1.0, 1.0, 1.0, 1.0, 1.0));
    f.w.pop();
    let e = run(fb(
        0,
        0.5,
        0,
        Some(NonConv {
            mask: vec![1; c.nx * c.ny],
            field: Some(f),
        }),
    ))
    .err()
    .expect("field length");
    assert!(e.to_string().contains("nonconv.field.w"), "{e}");
}

#[test]
fn cancel_before_the_start_with_everything_frozen_is_the_background() {
    for name in ["flat_wind", "heated_slope"] {
        let c = load(name);
        let flag = Arc::new(AtomicBool::new(true));
        let all = Freeze {
            mask: vec![1; c.nx * c.ny],
            field: None,
        };
        let run = |cancel: Option<Arc<AtomicBool>>| {
            api::solve(
                &c,
                &SolveOpts {
                    freeze: Some(all.clone()),
                    cancel,
                    ..base(2)
                },
            )
            .unwrap()
        };
        let cancelled = run(Some(flag));
        let free = run(None);
        assert_eq!(
            (cancelled.stop, cancelled.iters),
            (StopReason::AllFrozen, 0)
        );
        assert_eq!(free.stop, StopReason::AllFrozen);
        // The background (not zeros): the same field as without the flag, bit for bit.
        same_state(name, &cancelled, &free);
        if name == "flat_wind" {
            // (the heated case starts calm: its background is zero by itself)
            assert!(cancelled.state.u.iter().any(|&x| x != 0.0), "{name}: zeros");
        }
    }
}

/// Long: the 400 m Ongudai case in a calm at 12:00 (`docs/guide/air-model/limits.md`: 161
/// iterations in the game). Not a parity test: it must converge without the fallback path.
#[test]
#[ignore = "400 m Ongudai case from ~/data, release only"]
fn ongudai_calm_converges_without_the_fallback_path() {
    let p = PathBuf::from(std::env::var("HOME").unwrap())
        .join("data/air_cascade/ongudai/ongudai_d400_u0_heat.json");
    if !p.exists() {
        eprintln!("no Ongudai case, skipped");
        return;
    }
    let c = Case::load(&p).unwrap();
    let r = api::solve(
        &c,
        &SolveOpts {
            threads: 0,
            max_iters: 3000,
            fallback: Some(fb(300, 0.5, 500, None)),
            ..SolveOpts::default()
        },
    )
    .unwrap();
    eprintln!(
        "calm: stop {:?} iters {} omega_used {} nonconv {}",
        r.stop, r.iters, r.omega_fallback_used, r.nonconv_fallback
    );
    assert_eq!(r.stop, StopReason::Converged);
    assert!(!r.nonconv_fallback);
}

/// Long: fallback = None vs an inert fallback on Ongudai (bit for bit), a stripe `nonconv`.
#[test]
#[ignore = "400 m Ongudai case from ~/data, release only"]
fn ongudai_none_is_bitwise_v2() {
    let p = PathBuf::from(std::env::var("HOME").unwrap())
        .join("data/air_cascade/ongudai/ongudai_d400_u3_heat.json");
    if !p.exists() {
        eprintln!("no Ongudai case, skipped");
        return;
    }
    let c = Case::load(&p).unwrap();
    let few = |fallback| SolveOpts {
        threads: 0,
        max_iters: 30,
        fallback,
        ..SolveOpts::default()
    };
    let a = api::solve(&c, &few(None)).unwrap();
    let b = api::solve(&c, &few(Some(fb(100_000, 0.5, 0, None)))).unwrap();
    same_history("ongudai", &a, &b);
    same_state("ongudai", &a, &b);
}
