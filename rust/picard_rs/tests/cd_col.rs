//! W11 v4: the wall drag coefficient per column (`Case.cd_col`, the game's column plane 12,
//! `air_picard.glsl:393`) and the game's count of the fallback thresholds (`air_picard_job.gd`:
//! `_iters` in whole checks, without the cold-start `pre_steps`).
//!
//! Cases: `flat_wind` and `heated_slope` of the repository fixtures. The Ongudai test (400 m,
//! 38 MB, `~/data/air_cascade/ongudai`) is `#[ignore]`d: run it with
//! `cargo test --release -p picard_rs --test cd_col -- --ignored --nocapture`.

use picard_rs::api::{self, Fallback, SolveOpts, Solved, StopReason};
use picard_rs::case::Case;
use std::path::PathBuf;

fn load(name: &str) -> Case {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/atmosphere/fixtures/air_model/ref")
        .join(format!("{name}.json"));
    Case::load(&p).unwrap_or_else(|e| panic!("load {name}: {e}"))
}

fn bits_eq(x: &[f32], y: &[f32]) -> bool {
    x.len() == y.len() && x.iter().zip(y).all(|(p, q)| p.to_bits() == q.to_bits())
}

fn same(name: &str, a: &Solved, b: &Solved) {
    assert_eq!(a.iters, b.iters, "{name}: iters");
    assert_eq!(a.stop, b.stop, "{name}: stop");
    for (f, x, y) in [
        ("u", &a.state.u, &b.state.u),
        ("v", &a.state.v, &b.state.v),
        ("w", &a.state.w, &b.state.w),
        ("th", &a.state.th, &b.state.th),
        ("thd", &a.state.thd, &b.state.thd),
        ("p", &a.state.p, &b.state.p),
    ] {
        assert!(bits_eq(x, y), "{name}: {f} differs");
    }
}

fn base() -> SolveOpts {
    SolveOpts {
        threads: 2,
        ..SolveOpts::default()
    }
}

#[test]
fn constant_map_is_bitwise_none() {
    for name in ["flat_wind", "heated_slope"] {
        let mut c = load(name);
        assert!(c.cd_col.is_none());
        let none = api::solve(&c, &base()).unwrap();
        assert_eq!(none.stop, StopReason::Converged, "{name}");
        c.cd_col = Some(vec![c.cd; c.nxh * c.nyh]);
        let map = api::solve(&c, &base()).unwrap();
        same(name, &none, &map);
    }
}

#[test]
fn map_length_is_checked() {
    let c = load("flat_wind");
    let e = Case::from_parts(picard_rs::case::CaseParts {
        name: "x".into(),
        path: String::new(),
        dims: [c.nxh, c.nyh, c.nzh],
        nx: c.nx,
        ny: c.ny,
        nz: c.nz,
        dx: f64::from(c.dx),
        dz: f64::from(c.dz),
        z_bot: f64::from(c.z_bot),
        params: c.params.clone(),
        case_params: c.case_params.clone(),
        criterion: c.criterion.clone(),
        solution: None,
        history: None,
        crop: None,
        cd: None,
        cd_col: Some(vec![0.01; 5]),
        arrays: c.arrays.clone(),
    })
    .err()
    .expect("short cd_col");
    assert!(e.to_string().contains("cd_col"), "{e}");
}

/// Two covers: the left third of the columns with a small `C_d`, the right third with a large
/// one. More wall drag - slower air at the ground, and not otherwise.
#[test]
fn two_covers_slow_the_air_where_drag_is_larger() {
    let mut c = load("flat_wind");
    let (nxh, nyh) = (c.nxh, c.nyh);
    let (lo, hi) = (0.25 * c.cd, 4.0 * c.cd);
    let third = nxh / 3;
    let mut map = vec![c.cd; nxh * nyh];
    for j in 0..nyh {
        for i in 0..nxh {
            if i < third {
                map[j * nxh + i] = lo;
            } else if i >= nxh - third {
                map[j * nxh + i] = hi;
            }
        }
    }
    c.cd_col = Some(map);
    let r = api::solve(&c, &base()).unwrap();
    assert_eq!(r.stop, StopReason::Converged);
    // Mean ground speed (the first air level, k = 2 of the flat fixture) in each third, against
    // the run with the one coefficient `cd` everywhere.
    let c1 = load("flat_wind");
    let one = api::solve(&c1, &base()).unwrap();
    assert!(!bits_eq(&one.state.u, &r.state.u));
    let delta = |i0: usize, i1: usize| {
        let (mut s, mut n) = (0.0f64, 0usize);
        for j in 2..nyh - 2 {
            for i in i0..i1 {
                let q = (2 * nyh + j) * nxh + i;
                let sp = |x: &Solved| f64::from(x.state.u[q].hypot(x.state.v[q]));
                s += sp(&r) - sp(&one);
                n += 1;
            }
        }
        s / n as f64
    };
    let (d_lo, d_hi) = (delta(1, third - 2), delta(nxh - third + 2, nxh - 1));
    eprintln!("ground speed change: low C_d {d_lo:+.3}, high C_d {d_hi:+.3} m/s");
    assert!(d_lo > 0.05 && d_hi < -0.05, "{d_lo} {d_hi}");
}

fn fb(omega_after: usize, late_from: usize) -> Option<Fallback> {
    Some(Fallback {
        omega_after,
        omega: 0.5,
        late_from,
        nonconv: None,
    })
}

/// Thresholds that are not multiples of `check_every`, with a cold-start `pre_steps` != 0: the
/// switch is at the first check whose game count `it - pre_steps` reaches the threshold, i.e.
/// `omega_after = ce + 1` is the same as `2 ce`, and `2 ce + 1` is the same as `3 ce`.
#[test]
fn thresholds_count_like_the_game() {
    let mut c = load("flat_wind");
    let ce = c.criterion.check_every;
    assert!(ce >= 2);
    c.criterion.pre_steps = 3;
    let end = c.criterion.pre_steps + 5 * ce;
    let run = |fallback| {
        api::solve(
            &c,
            &SolveOpts {
                max_iters: end,
                tol_scale: 1e-9,
                fallback,
                ..base()
            },
        )
        .unwrap()
    };
    for (name, mk) in [
        (
            "omega_after",
            (|a| fb(a, 0)) as fn(usize) -> Option<Fallback>,
        ),
        ("late_from", |a| fb(0, a)),
    ] {
        let exact2 = run(mk(2 * ce));
        let off2 = run(mk(ce + 1));
        let exact3 = run(mk(3 * ce));
        let off3 = run(mk(2 * ce + 1));
        assert_eq!(exact2.stop, StopReason::MaxIters);
        same(&format!("{name} ce+1 = 2ce"), &exact2, &off2);
        same(&format!("{name} 2ce+1 = 3ce"), &exact3, &off3);
        assert!(
            !bits_eq(&exact2.state.u, &exact3.state.u),
            "{name}: 2ce and 3ce differ"
        );
    }
    // The raw count (with pre_steps) would have switched one check earlier: omega_after = 2 ce
    // must not act at the raw check pre + ce... it acts at pre + 2 ce.
    let rolled = run(fb(2 * ce, 0));
    let plain = run(None);
    let first_diff = rolled
        .history
        .iter()
        .zip(&plain.history)
        .position(|(a, b)| a.res.mom_rms.to_bits() != b.res.mom_rms.to_bits())
        .expect("omega acts");
    // history[i] is the check at pre + (i + 1) ce; the switch is after check 2 (game it = 2 ce),
    // the first different check is the 3rd.
    assert_eq!(first_diff, 2);
}
