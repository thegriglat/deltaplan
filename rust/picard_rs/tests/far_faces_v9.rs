//! W11 v9 (уточн., RW-6x): дальние грани тёплых стартов берут граничные значения случая, как
//! `K_BC` (`air_picard.glsl`): u, v типа 3 - `ubg`/`vbg` (у области - фон, у окна с `nest` -
//! значения родителя, `window_solver_case` кладёт их туда же), w типа >= 2 - `nest.ubw`, без
//! `nest` - 0. Итерации дальних граней не трогают, поэтому проверка - на отданном состоянии.

use picard_rs::api::{self, SolveOpts};
use picard_rs::case::{Case, Consts, NestBc};
use picard_rs::state::State;
use std::path::PathBuf;

fn load(name: &str) -> Case {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/atmosphere/fixtures/air_model/ref")
        .join(format!("{name}.json"));
    Case::load(&p).unwrap_or_else(|e| panic!("load {name}: {e}"))
}

fn opts(init: Option<State>, init_cycles: Option<u32>) -> SolveOpts {
    SolveOpts {
        threads: 2,
        max_iters: 3,
        init,
        init_cycles,
        ..SolveOpts::default()
    }
}

/// Состояние с чужими (ненулевыми, не фоновыми) значениями на всех гранях.
fn alien(c: &Case) -> State {
    let mut st = api::solve(c, &opts(None, None)).unwrap().state;
    st.u.fill(9.5);
    st.v.fill(-7.5);
    st.w.fill(4.5);
    st
}

/// (число дальних граней u+v, число дальних граней w) и сверка с ожидаемым.
fn check(
    c: &Case,
    st: &State,
    want_w: impl Fn(&Consts, usize) -> f32,
    what: &str,
) -> (usize, usize) {
    let k = Consts::from_case(c).unwrap();
    let (mut nuv, mut nw) = (0, 0);
    for i in 0..k.n3() {
        if k.tu[i] == 3 {
            assert_eq!(st.u[i], k.ubg[i], "{what}: u[{i}]");
            nuv += 1;
        }
        if k.tv[i] == 3 {
            assert_eq!(st.v[i], k.vbg[i], "{what}: v[{i}]");
            nuv += 1;
        }
        if k.tw[i] >= 2 {
            assert_eq!(st.w[i], want_w(&k, i), "{what}: w[{i}]");
            nw += 1;
        }
    }
    (nuv, nw)
}

fn both_starts(
    c: &Case,
    want_w: impl Fn(&Consts, usize) -> f32 + Copy,
    what: &str,
) -> (usize, usize) {
    let st = alien(c);
    let a = api::solve(c, &opts(Some(st.clone()), None)).unwrap();
    let b = api::solve(c, &opts(Some(st), Some(4))).unwrap();
    let ra = check(c, &a.state, want_w, &format!("{what} init_warm"));
    let rb = check(c, &b.state, want_w, &format!("{what} init_parent"));
    assert_eq!(ra, rb);
    ra
}

#[test]
fn area_far_faces_take_background_and_zero_w() {
    for name in ["flat_wind", "heated_slope"] {
        let c = load(name);
        let (nuv, _) = both_starts(&c, |_, _| 0.0, name);
        assert!(nuv > 0, "{name}: нет дальних граней u, v - тест пуст");
    }
}

#[test]
fn window_far_faces_take_boundary_values_of_the_case() {
    for name in ["flat_wind", "heated_slope"] {
        let mut c = load(name);
        let n = c.n3();
        // Граница родителя: своя у каждой грани, не фон и не ноль.
        let pat = |s: f32| {
            (0..n)
                .map(|i| s + (i % 7) as f32 * 0.25)
                .collect::<Vec<f32>>()
        };
        c.arrays.insert("ubg".into(), pat(1.5));
        c.arrays.insert("vbg".into(), pat(-2.5));
        let ubw = pat(0.5);
        c.nest = Some(NestBc {
            ubw: ubw.clone(),
            thb: vec![0.0; n],
            thbd: None,
        });
        let (nuv, nw) = both_starts(&c, |_, i| ubw[i], name);
        assert!(nuv > 0, "{name}: нет дальних граней u, v - тест пуст");
        assert!(nw > 0, "{name}: нет граней w типа >= 2 - тест пуст");
    }
}
