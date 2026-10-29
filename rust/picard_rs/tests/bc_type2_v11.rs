//! W11 v11: θ′ и θ′_d во всех не-неизвестных клетках (`cell != 1`: земля, кольцо, верх, ореол)
//! после любого старта и после `finalize` — без `nest` ровно 0, с `nest` в клетках типа 2 —
//! `thb`/`thbd` (остальные не-неизвестные — 0), как `K_BC` игры (`air_picard.glsl:237-238`).

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

const THB: f32 = 0.6;
const THBD: f32 = 0.25;

/// Ожидаемые (θ′, θ′_d) в не-неизвестной клетке типа `cell`.
fn want(nest: bool, cell: u8) -> (f32, f32) {
    if nest && cell == 2 {
        (THB, THBD)
    } else {
        (0.0, 0.0)
    }
}

fn violations(c: &Case, st: &State, nest: bool) -> usize {
    let k = Consts::from_case(c).unwrap();
    (0..k.n3())
        .filter(|&i| k.cell[i] != 1)
        .filter(|&i| (st.th[i], st.thd[i]) != want(nest, k.cell[i]))
        .count()
}

/// Состояние решения с θ′, θ′_d, испорченными во всех не-неизвестных клетках.
fn spoiled(c: &Case) -> State {
    let mut st = api::solve(c, &opts(None, None)).unwrap().state;
    let k = Consts::from_case(c).unwrap();
    let mut ring = 0;
    for i in 0..k.n3() {
        if k.cell[i] != 1 {
            st.th[i] = 1.5;
            st.thd[i] = 0.5;
            ring += usize::from(k.cell[i] != 0);
        }
    }
    assert!(ring > 0, "нет не-неизвестных клеток вне земли");
    st
}

fn check(c: &Case, nest: bool, tag: &str) {
    let st = spoiled(c);
    assert!(violations(c, &st, nest) > 0);
    let w = api::solve(c, &opts(Some(st.clone()), None)).unwrap();
    assert_eq!(violations(c, &w.state, nest), 0, "{tag}: init_warm");
    let p = api::solve(c, &opts(Some(st), Some(4))).unwrap();
    assert_eq!(violations(c, &p.state, nest), 0, "{tag}: init_parent");
    let cold = api::solve(c, &opts(None, None)).unwrap();
    assert_eq!(violations(c, &cold.state, nest), 0, "{tag}: холодный");
}

#[test]
fn non_unknown_cells_are_zero_without_nest() {
    for name in ["flat_wind", "heated_slope"] {
        check(&load(name), false, name);
    }
}

#[test]
fn halo_takes_nest_values_other_non_unknown_zero() {
    for name in ["flat_wind", "heated_slope"] {
        let mut c = load(name);
        let n = c.n3();
        c.nest = Some(NestBc {
            ubw: vec![0.0; n],
            thb: vec![THB; n],
            thbd: Some(vec![THBD; n]),
        });
        check(&c, true, name);
    }
}
