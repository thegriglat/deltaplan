//! OB1 v1 (`docs/contracts/outflow-bc.md`): the soft outflow behind `SolveOpts.outflow`.

use picard_rs::api::{self, Outflow, SolveOpts, Solved, StopReason};
use picard_rs::case::{Case, NestBc};
use picard_rs::solver::Picard;
use std::path::PathBuf;

const FIXTURES: [&str; 4] = ["flat_wind", "agnesi", "heated_slope", "saddle"];

fn load(name: &str) -> Case {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../tests/atmosphere/fixtures/air_model/ref/{name}.json"
    ));
    Case::load(&p).unwrap_or_else(|e| panic!("load {name}: {e}"))
}

/// FNV-1a 64 over the f32 LE bytes of `u, v, w, p, th, thd`, then the iteration count.
fn state_hash(r: &Solved) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |b: u8| {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    };
    for a in [
        &r.state.u,
        &r.state.v,
        &r.state.w,
        &r.state.p,
        &r.state.th,
        &r.state.thd,
    ] {
        for x in a.iter() {
            x.to_le_bytes().into_iter().for_each(&mut eat);
        }
    }
    (r.iters as u64)
        .to_le_bytes()
        .into_iter()
        .for_each(&mut eat);
    h
}

fn run(name: &str, threads: usize, outflow: Outflow) -> Solved {
    api::solve(
        &load(name),
        &SolveOpts {
            threads,
            outflow,
            ..SolveOpts::default()
        },
    )
    .unwrap()
}

/// Hashes of the delivered state (and `iters`) taken on the commit before OB1 (hard outflow),
/// the same at 1 and 4 threads. They depend on the CPU branch (AVX2+FMA dispatch).
const HARD_HASH: [(&str, u64, usize); 4] = [
    ("flat_wind", 0xed9ec61c64add9d2, 30),
    ("agnesi", 0xc170524e1b8cd33b, 780),
    ("heated_slope", 0x7af9d9641aa150fa, 60),
    ("saddle", 0x7d2857688b1bf33b, 470),
];

#[test]
fn hard_and_default_are_bitwise_the_old_state() {
    for (n, h, it) in HARD_HASH {
        for t in [1, 4] {
            let dflt = api::solve(
                &load(n),
                &SolveOpts {
                    threads: t,
                    ..SolveOpts::default()
                },
            )
            .unwrap();
            assert_eq!((dflt.iters, state_hash(&dflt)), (it, h), "{n} t{t} default");
            let hard = run(n, t, Outflow::Hard);
            assert_eq!((hard.iters, state_hash(&hard)), (it, h), "{n} t{t} hard");
            assert!(hard.outflow.is_none() && dflt.outflow.is_none());
        }
    }
}

fn div_rms(r: &Solved) -> f64 {
    let k: &picard_rs::case::Consts = &r.picard.k;
    let f = &r.picard.f;
    let mut d = vec![0.0f32; k.nx * k.ny * k.nz];
    r.pool
        .install(|| Picard::divergence(k, &f.u, &f.v, &f.w, &mut d));
    (d.iter().map(|&x| f64::from(x).powi(2)).sum::<f64>() / k.n_fluid).sqrt()
}

#[test]
fn soft_converges_and_balances_the_flux() {
    for n in FIXTURES {
        let r = run(n, 2, Outflow::Soft);
        assert_eq!(r.stop, StopReason::Converged, "{n}");
        let d = r.outflow.expect("soft gives the diagnostics");
        println!("{n}: iters {} {d:?} div_rms {:.3e}", r.iters, div_rms(&r));
        // heated_slope is calm (u10 = 0): the soft outflow is the hard one, no outflow faces.
        let calm = load(n).case_params.u10 <= 0.0;
        assert_eq!(d.faces_out == 0, calm, "{n}: {d:?}");
        assert!(calm || d.flux_in > 0.0, "{n}: {d:?}");
        assert!(d.flux_net_max_rel <= 1e-6, "{n}: {d:?}");
        let crit = load(n).criterion.tol_div_rms;
        assert!(div_rms(&r) <= crit, "{n}: div {} > {crit}", div_rms(&r));
    }
}

#[test]
fn soft_is_bitwise_equal_at_1_and_4_threads() {
    for n in FIXTURES {
        let (a, b) = (run(n, 1, Outflow::Soft), run(n, 4, Outflow::Soft));
        assert_eq!(a.iters, b.iters, "{n}");
        assert_eq!(state_hash(&a), state_hash(&b), "{n}");
        assert_eq!(a.outflow, b.outflow, "{n}");
    }
}

#[test]
fn soft_differs_from_hard() {
    let (h, s) = (
        run("agnesi", 2, Outflow::Hard),
        run("agnesi", 2, Outflow::Soft),
    );
    assert_ne!(state_hash(&h), state_hash(&s));
}

#[test]
fn soft_with_a_nest_is_an_error() {
    let mut c = load("flat_wind");
    let n = c.n3();
    c.nest = Some(NestBc {
        ubw: vec![0.0; n],
        thb: vec![0.0; n],
        thbd: None,
    });
    let e = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            outflow: Outflow::Soft,
            ..SolveOpts::default()
        },
    );
    let msg = e.err().expect("error").to_string();
    assert!(msg.contains("nest"), "{msg}");
}
