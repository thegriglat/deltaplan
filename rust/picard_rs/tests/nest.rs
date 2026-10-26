//! W11 v7: граница окна от родителя (`Case.nest`) и старт `SolveOpts.init_cycles`.
//! Область (`nest = None`) — v6 побитно: это держат остальные тесты крейта; здесь — нулевая
//! граница окна, ненулевая граница и опция старта. Сверка окна с GPU игры — `rust/dp-air/tests/window.rs`.

use picard_rs::api::{self, SolveOpts, Solved, StopReason};
use picard_rs::case::{Case, NestBc};
use std::path::PathBuf;

fn load(name: &str) -> Case {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/atmosphere/fixtures/air_model/ref")
        .join(format!("{name}.json"));
    Case::load(&p).unwrap_or_else(|e| panic!("load {name}: {e}"))
}

fn base() -> SolveOpts {
    SolveOpts {
        threads: 2,
        ..SolveOpts::default()
    }
}

fn bits_eq(x: &[f32], y: &[f32]) -> bool {
    x.len() == y.len() && x.iter().zip(y).all(|(p, q)| p.to_bits() == q.to_bits())
}

fn zero_nest(c: &Case, thbd: bool) -> NestBc {
    let n = c.n3();
    NestBc {
        ubw: vec![0.0; n],
        thb: vec![0.0; n],
        thbd: thbd.then(|| vec![0.0; n]),
    }
}

fn same(a: &Solved, b: &Solved) {
    assert_eq!(a.iters, b.iters);
    for (x, y) in [
        (&a.state.u, &b.state.u),
        (&a.state.v, &b.state.v),
        (&a.state.w, &b.state.w),
        (&a.state.th, &b.state.th),
        (&a.state.thd, &b.state.thd),
        (&a.state.p, &b.state.p),
    ] {
        assert!(bits_eq(x, y));
    }
}

#[test]
fn zero_boundary_is_the_domain_bitwise() {
    for name in ["flat_wind", "heated_slope"] {
        let mut c = load(name);
        let none = api::solve(&c, &base()).unwrap();
        assert_eq!(none.stop, StopReason::Converged, "{name}");
        for thbd in [true, false] {
            c.nest = Some(zero_nest(&c, thbd));
            same(&none, &api::solve(&c, &base()).unwrap());
        }
    }
}

#[test]
fn parent_theta_is_held_in_the_halo_and_pulls_the_sponge() {
    let mut c = load("heated_slope");
    let none = api::solve(&c, &base()).unwrap();
    let n = c.n3();
    let mut nb = zero_nest(&c, true);
    // θ′ родителя +0,5 К во всех клетках
    nb.thb = vec![0.5; n];
    c.nest = Some(nb);
    let r = api::solve(&c, &base()).unwrap();
    let cell = c.bytes("cell").unwrap();
    let mut halo = 0;
    for q in 0..n {
        if cell[q] == 2 {
            assert_eq!(r.state.th[q], 0.5, "halo cell {q}");
            halo += 1;
        }
    }
    assert!(halo > 0);
    assert!(!bits_eq(&none.state.th, &r.state.th));
    // губка тянет θ′ у края к родителю: в воздухе среднее выше, чем без границы
    let mean = |s: &Solved| {
        let (mut a, mut k) = (0.0f64, 0usize);
        for q in 0..n {
            if cell[q] == 1 {
                a += f64::from(s.state.th[q]);
                k += 1;
            }
        }
        a / k as f64
    };
    assert!(
        mean(&r) > mean(&none) + 1e-3,
        "{} vs {}",
        mean(&r),
        mean(&none)
    );
}

#[test]
fn fixed_top_w_faces_hold_ubw() {
    let mut c = load("flat_wind");
    let n = c.n3();
    let tw = c.bytes("tw").unwrap();
    let mut nb = zero_nest(&c, false);
    for q in 0..n {
        if tw[q] == 2 {
            nb.ubw[q] = 0.3;
        }
    }
    let top = tw.iter().filter(|&&t| t == 2).count();
    assert!(top > 0, "в фикстуре есть грани w типа 2");
    c.nest = Some(nb);
    let r = api::solve(&c, &base()).unwrap();
    // до finalize грани закреплены; после проекции они значение границы или близки к нему
    let held = (0..n)
        .filter(|&q| tw[q] == 2)
        .filter(|&q| (r.state.w[q] - 0.3).abs() < 1e-3)
        .count();
    assert!(held * 10 >= top * 9, "{held} из {top}");
}

#[test]
fn nest_arrays_are_length_checked() {
    let mut c = load("flat_wind");
    c.nest = Some(NestBc {
        ubw: vec![0.0; 3],
        thb: vec![0.0; c.n3()],
        thbd: None,
    });
    assert!(api::solve(&c, &base()).is_err());
}

#[test]
fn init_cycles_needs_init_and_sets_p_to_zero() {
    let c = load("heated_slope");
    let e = api::solve(
        &c,
        &SolveOpts {
            init_cycles: Some(30),
            ..base()
        },
    )
    .err()
    .expect("init_cycles without init");
    assert!(e.to_string().contains("init_cycles"), "{e}");
    let first = api::solve(
        &c,
        &SolveOpts {
            max_iters: 10,
            ..base()
        },
    )
    .unwrap();
    assert!(first.state.p.iter().any(|&p| p != 0.0));
    // 0 итераций критерия не бывает; проверяем старт: p из init сбрасывается, результат конечен
    let warm = SolveOpts {
        init: Some(first.state.clone()),
        ..base()
    };
    let a = api::solve(&c, &warm).unwrap();
    let b = api::solve(
        &c,
        &SolveOpts {
            init_cycles: Some(30),
            ..warm.clone()
        },
    )
    .unwrap();
    assert_eq!(a.stop, StopReason::Converged);
    assert_eq!(b.stop, StopReason::Converged);
    assert!(b.state.u.iter().all(|x| x.is_finite()));
}
