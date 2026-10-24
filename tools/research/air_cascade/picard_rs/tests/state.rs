//! R4 v2: `State::write_atomic` / `State::read` round trip, tolerant and strict reads.

use picard_rs::api::{self, SolveOpts};
use picard_rs::case::Case;
use picard_rs::state::State;
use std::path::PathBuf;

fn tmp(name: &str) -> PathBuf {
    let d = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("state_tests");
    std::fs::create_dir_all(&d).unwrap();
    d.join(name)
}

fn solved_state() -> (Case, State) {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../../tests/atmosphere/fixtures/air_model/ref/flat_wind.json");
    let c = Case::load(&p).expect("load flat_wind");
    let r = api::solve(
        &c,
        &SolveOpts {
            threads: 2,
            max_iters: 12,
            ..SolveOpts::default()
        },
    )
    .unwrap();
    (c, r.state)
}

fn same(x: &[f32], y: &[f32]) -> bool {
    x.len() == y.len() && x.iter().zip(y).all(|(p, q)| p.to_bits() == q.to_bits())
}

#[test]
fn write_then_read_is_bitwise() {
    let (_, mut st) = solved_state();
    st.u[3] = f32::from_bits(0x7fc0_1234); // a NaN payload must survive
    let path = tmp("roundtrip.json");
    st.write_atomic(&path).unwrap();
    assert!(path.with_extension("bin").exists());
    assert!(!path.with_extension("json.tmp").exists() && !path.with_extension("bin.tmp").exists());
    let back = State::read(&path).unwrap();
    assert_eq!(
        (back.it, back.dims, back.halo, back.n),
        (st.it, st.dims, 1, st.n)
    );
    assert_eq!((&back.case, &back.input), (&st.case, &st.input));
    for (a, b) in [
        (&st.u, &back.u),
        (&st.v, &back.v),
        (&st.w, &back.w),
        (&st.th, &back.th),
        (&st.thd, &back.thd),
        (&st.p, &back.p),
        (st.nu.as_ref().unwrap(), back.nu.as_ref().unwrap()),
        (st.nuh.as_ref().unwrap(), back.nuh.as_ref().unwrap()),
    ] {
        assert!(same(a, b));
    }
    // JSON decimal text: compare the residual record by value, not by bits.
    let (a, b) = (back.residuals.unwrap(), st.residuals.unwrap());
    assert_eq!(a["it"], b["it"]);
    let (x, y) = (
        a["mom_rms"].as_f64().unwrap(),
        b["mom_rms"].as_f64().unwrap(),
    );
    assert!((x - y).abs() <= 1e-12 * y.abs());
}

#[test]
fn missing_thd_is_zeros_missing_required_is_error() {
    let (_, st) = solved_state();
    let path = tmp("nothd.json");
    st.write_atomic(&path).unwrap();
    let mut d: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    d["arrays"].as_object_mut().unwrap().remove("thd");
    std::fs::write(&path, d.to_string()).unwrap();
    let back = State::read(&path).unwrap();
    assert!(back.thd.iter().all(|&x| x == 0.0) && back.thd.len() == st.n3());
    d["arrays"].as_object_mut().unwrap().remove("p");
    std::fs::write(&path, d.to_string()).unwrap();
    assert!(State::read(&path).is_err());
    d["format"] = serde_json::json!("other");
    std::fs::write(&path, d.to_string()).unwrap();
    assert!(State::read(&path).is_err());
}

#[test]
fn dims_must_match_the_case() {
    let (c, st) = solved_state();
    let k = picard_rs::case::Consts::from_case(&c).unwrap();
    st.check_dims(&k).unwrap();
    let mut bad = st.clone();
    bad.dims[2] += 1;
    assert!(bad.check_dims(&k).is_err());
    let mut bad = st.clone();
    bad.halo = 2;
    assert!(bad.check_dims(&k).is_err());
    let mut bad = st;
    bad.p.push(0.0);
    assert!(bad.check_dims(&k).is_err());
}
