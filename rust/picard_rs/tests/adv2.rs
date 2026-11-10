//! PT3: deferred second-order advection correction (limiters 0..3) and its CLI/R2 plumbing.

use picard_rs::adv2::{self, Limiter};
use picard_rs::api::{self, SolveOpts};
use picard_rs::blocks::check_case;
use picard_rs::case::{Case, Consts};
use picard_rs::kernels::Vel;
use std::path::PathBuf;

const LIMS: [Limiter; 4] = [
    Limiter::Linear,
    Limiter::VanLeer,
    Limiter::VanAlbada,
    Limiter::MinMod,
];

fn ref_case(name: &str) -> Case {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join(format!("../../tests/atmosphere/fixtures/air_model/ref/{name}.json"));
    Case::load(&p).expect("load ref case")
}

#[test]
fn limiter_slopes() {
    // equal differences (a smooth linear field): every limiter returns the difference
    for l in LIMS {
        assert!((l.slope(2.0, 2.0) - 2.0).abs() < 1e-6, "{l:?}");
        assert!((l.slope(-3.0, -3.0) + 3.0).abs() < 1e-6, "{l:?}");
    }
    // extremum (opposite signs) and a zero difference: no slope, except the linear scheme
    for l in [Limiter::VanLeer, Limiter::VanAlbada, Limiter::MinMod] {
        assert_eq!(l.slope(1.0, -1.0), 0.0, "{l:?}");
        assert_eq!(l.slope(0.0, 1.0), 0.0, "{l:?}");
        assert_eq!(l.slope(1.0, 0.0), 0.0, "{l:?}");
    }
    assert_eq!(Limiter::Linear.slope(1.0, -1.0), 1.0);
    // van Leer is the harmonic mean, minmod the smaller magnitude
    assert!((Limiter::VanLeer.slope(1.0, 3.0) - 1.5).abs() < 1e-6);
    assert_eq!(Limiter::MinMod.slope(1.0, 3.0), 1.0);
    assert_eq!(Limiter::MinMod.slope(3.0, 1.0), 1.0);
    assert_eq!(Limiter::MinMod.slope(-3.0, -1.0), -1.0);
    // phi(r) = max(0, min(1, r)): minmod is the lowest of the TVD limiters here
    for (a, b) in [(1.0f32, 0.5), (1.0, 2.0), (2.0, 7.0), (-1.0, -0.2)] {
        assert!(Limiter::MinMod.slope(a, b).abs() <= Limiter::VanLeer.slope(a, b).abs() + 1e-6);
    }
    assert_eq!(Limiter::from_name("minmod").unwrap(), Limiter::MinMod);
    assert!(Limiter::from_name("nope").is_err());
    assert!(Limiter::from_index(4).is_err());
}

/// Row of cells `(i, j0, k0)` for the 1D tests on a ref case (halo layout indices).
fn row(k: &Consts) -> (usize, usize) {
    (k.nyh / 2, k.nzh / 2)
}

#[test]
fn heat_correction_linear_field_is_zero_and_step_is_tvd() {
    let c = ref_case("flat_wind");
    let k = Consts::from_case(&c).unwrap();
    let n3 = k.n3();
    let (nxh, nyh) = (k.nxh, k.nyh);
    let (j0, k0) = row(&k);
    let (u, zero) = (vec![1.0f32; n3], vec![0.0f32; n3]);
    let vel = Vel {
        u: &u,
        v: &zero,
        w: &zero,
    };
    let at = |i: usize| (k0 * nyh + j0) * nxh + i;
    for lim in LIMS {
        // linear ramp: D_2 = D_1, the correction vanishes away from the edges
        let mut th = vec![0.0f32; n3];
        for (q, t) in th.iter_mut().enumerate() {
            *t = 0.1 * (q % nxh) as f32;
        }
        let mut corr = vec![0.0f32; n3];
        adv2::adv2_heat(&k, lim, &vel, &th, &mut corr);
        for i in 4..nxh - 4 {
            assert!(corr[at(i)].abs() < 1e-5, "{lim:?} ramp i={i}: {}", corr[at(i)]);
        }
    }
    // front: upwind + correction with CFL 0.5 creates no new extremum for the TVD limiters
    for lim in [Limiter::VanLeer, Limiter::MinMod] {
        let mut th = vec![0.0f32; n3];
        for (q, t) in th.iter_mut().enumerate() {
            let i = q % nxh;
            // a smeared front (a sharp one has zero slope on both sides, nothing to correct)
            *t = if i < nxh / 2 {
                1.0
            } else if i == nxh / 2 {
                0.7
            } else if i == nxh / 2 + 1 {
                0.3
            } else {
                0.0
            };
        }
        let mut corr = vec![0.0f32; n3];
        adv2::adv2_heat(&k, lim, &vel, &th, &mut corr);
        let cfl = 0.5f32;
        let mut moved = false;
        for i in 4..nxh - 4 {
            // d(th)/dt = -u (th_i - th_{i-1}) / h - corr, dt u / h = cfl
            let new = th[at(i)] - cfl * (th[at(i)] - th[at(i - 1)]) - cfl * k.dx * corr[at(i)];
            assert!(
                (-1e-5..=1.0 + 1e-5).contains(&new),
                "{lim:?} i={i}: {new} out of [0, 1]"
            );
            moved |= corr[at(i)] != 0.0;
        }
        assert!(moved, "{lim:?}: the correction at a smeared front is not zero");
    }
}

#[test]
fn momentum_correction_vanishes_without_flow_and_for_uniform_flow() {
    let c = ref_case("flat_wind");
    let k = Consts::from_case(&c).unwrap();
    let n3 = k.n3();
    let (zero, one) = (vec![0.0f32; n3], vec![1.0f32; n3]);
    let mut corr = vec![9.0f32; n3];
    for lim in LIMS {
        for (name, vel) in [
            ("rest", Vel { u: &zero, v: &zero, w: &zero }),
            ("uniform", Vel { u: &one, v: &one, w: &one }),
        ] {
            for comp in 0..3 {
                adv2::adv2_mom(&k, lim, &vel, comp, &mut corr);
                assert!(
                    corr.iter().all(|&x| x == 0.0),
                    "{lim:?} {name} comp {comp}: nonzero correction"
                );
            }
        }
    }
}

#[test]
fn flat_wind_converges_with_every_limiter_and_close_to_first_order() {
    let base_c = ref_case("flat_wind");
    let opts = SolveOpts {
        threads: 2,
        max_iters: 400,
        ..SolveOpts::default()
    };
    let base = api::solve(&base_c, &opts).unwrap();
    assert_eq!(base.out.status, "ok");
    for (lim, l) in LIMS.iter().enumerate() {
        let mut c = ref_case("flat_wind");
        c.params.adv2 = true;
        c.params.limiter = lim as i64;
        let r = api::solve(&c, &opts).unwrap();
        assert_eq!(r.out.status, "ok", "{l:?}: not converged in {}", r.out.iters);
        let (a, b) = (&r.picard.f.u, &base.picard.f.u);
        let (mut e, mut m) = (0.0f32, 0.0f32);
        for (x, y) in a.iter().zip(b.iter()) {
            e = e.max((x - y).abs());
            m = m.max(y.abs());
        }
        assert!(e / m < 0.05, "{l:?}: u differs from first order by {}", e / m);
    }
}

#[test]
fn off_by_default_and_params_reach_consts() {
    let c = ref_case("agnesi");
    assert!(Consts::from_case(&c).unwrap().adv2.is_none());
    let mut c = ref_case("agnesi");
    c.params.adv2 = true;
    c.params.limiter = 3;
    assert_eq!(Consts::from_case(&c).unwrap().adv2, Some(Limiter::MinMod));
    c.params.limiter = 7;
    assert!(Consts::from_case(&c).is_err());
}

/// Fixtures of `adv2_fixtures.py` (air3d float64, adv2 limiter 0/1/2): all blocks of one
/// iteration, the stencils include the correction. Skipped when the data are not there.
#[test]
fn blocks_match_air3d_adv2_fixtures() {
    let d = std::env::var_os("PICARD_TERRAIN_DATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap()).join("data/picard_terrain"));
    let pl = api::pool(2).unwrap();
    let mut n = 0;
    for l in 0..3 {
        let p = d.join(format!("fixtures/adv2_l{l}.json"));
        if !p.exists() {
            eprintln!("skip: {p:?} not found (run tools/research/picard_terrain/adv2_fixtures.py)");
            continue;
        }
        n += 1;
        let c = Case::load(&p).unwrap();
        assert!(c.params.adv2 && c.params.limiter == l);
        let rows = pl.install(|| check_case(&c)).unwrap();
        for r in rows.iter().filter(|r| r.checked) {
            assert!(r.rel <= 1e-5, "limiter {l}: {} rel {}", r.name, r.rel);
        }
        // the correction is not vacuous: without it the stencil right-hand sides differ a lot
        let mut off = Case::load(&p).unwrap();
        off.params.adv2 = false;
        let rows = pl.install(|| check_case(&off)).unwrap();
        let worst = rows
            .iter()
            .filter(|r| r.name.starts_with("momentum stencil b") || r.name == "heat stencil theta b")
            .map(|r| r.rel)
            .fold(0.0, f64::max);
        assert!(worst > 1e-4, "limiter {l}: correction off differs only by {worst}");
    }
    let _ = n;
}
