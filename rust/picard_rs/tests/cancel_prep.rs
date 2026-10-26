//! W11 v6: отмена в подготовке решения — сборка уровней многосетки, V-циклы старта (фон и тёплый),
//! `finalize`. Фикстура `flat_wind`/`heated_slope` (мелкая: границы по стадиям — здесь, задержка
//! на области размера Онгудая — в `dp-air/tests/runtime.rs`, там есть настоящий случай).

use picard_rs::api::{self, SolveOpts, StopReason};
use picard_rs::case::{Case, Consts};
use picard_rs::solver::Picard;
use picard_rs::state::State;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

fn load(name: &str) -> Case {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/atmosphere/fixtures/air_model/ref")
        .join(format!("{name}.json"));
    Case::load(&p).unwrap_or_else(|e| panic!("load {name}: {e}"))
}

fn finite(s: &State) -> bool {
    [&s.u, &s.v, &s.w, &s.th, &s.thd, &s.p]
        .iter()
        .all(|a| a.iter().all(|x| x.is_finite()))
}

fn bits_eq(x: &[f32], y: &[f32]) -> bool {
    x.len() == y.len() && x.iter().zip(y).all(|(p, q)| p.to_bits() == q.to_bits())
}

#[test]
fn the_multigrid_build_stops_at_the_finest_level_once_cancelled() {
    let c = load("flat_wind");
    let full = Picard::new(Consts::from_case(&c).unwrap());
    assert!(full.mg.level_dims().len() > 1, "fixture must coarsen");
    let flag = Arc::new(AtomicBool::new(true));
    let cut = Picard::new_cancel(Consts::from_case(&c).unwrap(), Some(&flag));
    assert_eq!(cut.mg.level_dims().len(), 1);
    assert_eq!(cut.mg.level_dims()[0], full.mg.level_dims()[0]);
    // флаг, не взведённый до конца сборки, ничего не обрезает
    let off = Arc::new(AtomicBool::new(false));
    let same = Picard::new_cancel(Consts::from_case(&c).unwrap(), Some(&off));
    assert_eq!(same.mg.level_dims(), full.mg.level_dims());
}

#[test]
fn vcycle_until_is_the_vcycle_and_stops_when_asked() {
    let c = load("heated_slope");
    let mut a = Picard::new(Consts::from_case(&c).unwrap());
    let mut b = Picard::new(Consts::from_case(&c).unwrap());
    let n = a.mg.phi().len();
    let rhs: Vec<f32> = (0..n)
        .map(|i| ((i * 7919) % 1000) as f32 * 1e-3 - 0.5)
        .collect();
    a.mg.set_rhs(&rhs);
    b.mg.set_rhs(&rhs);
    a.mg.zero_phi();
    b.mg.zero_phi();
    a.mg.vcycle();
    assert!(b.mg.vcycle_until(&|| false));
    assert!(
        bits_eq(a.mg.phi(), b.mg.phi()),
        "never-stopping test is the plain cycle"
    );
    // остановка до работы: phi не тронут
    b.mg.zero_phi();
    assert!(!b.mg.vcycle_until(&|| true));
    assert!(b.mg.phi().iter().all(|&x| x == 0.0));
    // остановка в середине (после k вопросов): цикл прерван, phi конечен
    let asked = std::cell::Cell::new(0usize);
    let stop = || {
        asked.set(asked.get() + 1);
        asked.get() > 2
    };
    assert!(!b.mg.vcycle_until(&stop));
    assert!(b.mg.phi().iter().all(|x| x.is_finite()));
}

#[test]
fn cancelled_before_the_call_gives_a_finite_field_and_no_iterations() {
    for name in ["flat_wind", "heated_slope"] {
        let c = load(name);
        for warm in [false, true] {
            let init = warm.then(|| {
                api::solve(
                    &c,
                    &SolveOpts {
                        threads: 2,
                        max_iters: 20,
                        ..SolveOpts::default()
                    },
                )
                .unwrap()
                .state
            });
            let flag = Arc::new(AtomicBool::new(true));
            let t = Instant::now();
            let r = api::solve(
                &c,
                &SolveOpts {
                    threads: 2,
                    init,
                    cancel: Some(flag),
                    ..SolveOpts::default()
                },
            )
            .unwrap();
            let d = t.elapsed();
            assert_eq!(
                (r.stop, r.iters),
                (StopReason::Cancelled, 0),
                "{name} warm={warm}"
            );
            assert_eq!(r.out.status, "max");
            assert!(finite(&r.state), "{name} warm={warm}: finite");
            assert!(d < Duration::from_secs(2), "{name}: {d:?}");
        }
    }
}

#[test]
fn a_flag_that_comes_at_any_moment_of_the_setup_is_safe() {
    // Взводим флаг через разные интервалы после старта: подготовка, итерации, finalize — на
    // любой стадии ответ конечен, а отмена не позже конца ближайшей стадии.
    let c = load("heated_slope");
    for us in [0u64, 50, 200, 500, 1000, 2000, 4000, 8000, 16000, 32000] {
        let flag = Arc::new(AtomicBool::new(false));
        let f2 = flag.clone();
        let h = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_micros(us));
            f2.store(true, Ordering::Relaxed);
        });
        let r = api::solve(
            &c,
            &SolveOpts {
                threads: 2,
                cancel: Some(flag),
                tol_scale: 1e-9,
                max_iters: 1_000_000,
                ..SolveOpts::default()
            },
        )
        .unwrap();
        h.join().unwrap();
        assert_eq!(r.stop, StopReason::Cancelled, "after {us} us");
        assert!(finite(&r.state), "after {us} us");
    }
}

#[test]
fn the_flag_never_changes_a_run_that_ends_before_it() {
    // Взведённый после конца вызова флаг ничего не меняет: побитно тот же ответ, что без флага.
    let c = load("flat_wind");
    let plain = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            ..SolveOpts::default()
        },
    )
    .unwrap();
    let flag = Arc::new(AtomicBool::new(false));
    let with = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            cancel: Some(flag),
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!((plain.stop, plain.iters), (with.stop, with.iters));
    assert!(bits_eq(&plain.state.u, &with.state.u));
    assert!(bits_eq(&plain.state.p, &with.state.p));
}
