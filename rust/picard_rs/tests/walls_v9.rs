//! W11 v9: стенки (грани типа 0: `tu`/`tv`/`tw`) и клетки земли (`cell` == 0) после любого старта
//! и после `finalize` — ровно ноль, как в `K_BC` игры (`air_picard.glsl`). Без испорченного
//! входа — побитно как v8 (хеши сняты на коде v8).

use picard_rs::api::{self, SolveOpts, Solved};
use picard_rs::case::{Case, Consts};
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

fn fnv(r: &Solved) -> u64 {
    let mut h = 0xcbf2_9ce4_8422_2325u64;
    for a in [
        &r.state.u,
        &r.state.v,
        &r.state.w,
        &r.state.th,
        &r.state.thd,
        &r.state.p,
    ] {
        for x in a.iter() {
            h = (h ^ u64::from(x.to_bits())).wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    h
}

/// Число нарушений: ненулевые скорости на стенках и θ′/θ′_d в земле.
fn violations(c: &Case, st: &State) -> usize {
    let k = Consts::from_case(c).unwrap();
    let mut n = 0;
    for i in 0..k.n3() {
        n += usize::from(k.tu[i] == 0 && st.u[i] != 0.0);
        n += usize::from(k.tv[i] == 0 && st.v[i] != 0.0);
        n += usize::from(k.tw[i] == 0 && st.w[i] != 0.0);
        n += usize::from(k.cell[i] == 0 && (st.th[i] != 0.0 || st.thd[i] != 0.0));
    }
    n
}

fn spoiled(c: &Case) -> State {
    let mut st = api::solve(c, &opts(None, None)).unwrap().state;
    let k = Consts::from_case(c).unwrap();
    for i in 0..k.n3() {
        if k.tu[i] == 0 {
            st.u[i] = 0.7;
        }
        if k.tv[i] == 0 {
            st.v[i] = -0.4;
        }
        if k.tw[i] == 0 {
            st.w[i] = 0.3;
        }
        if k.cell[i] == 0 {
            st.th[i] = 1.5;
            st.thd[i] = 0.5;
        }
    }
    assert!(violations(c, &st) > 0, "испорчено нечего");
    st
}

#[test]
fn walls_are_zero_after_warm_parent_and_finalize() {
    for name in ["flat_wind", "heated_slope"] {
        let c = load(name);
        let st = spoiled(&c);
        let w = api::solve(&c, &opts(Some(st.clone()), None)).unwrap();
        assert_eq!(violations(&c, &w.state), 0, "{name}: init_warm");
        let p = api::solve(&c, &opts(Some(st), Some(4))).unwrap();
        assert_eq!(violations(&c, &p.state), 0, "{name}: init_parent");
        let cold = api::solve(&c, &opts(None, None)).unwrap();
        assert_eq!(violations(&c, &cold.state), 0, "{name}: холодный");
    }
}

/// Хеши v8 (чистый вход): правка не меняет то, что уже было нулём.
#[test]
fn clean_input_is_bitwise_v8() {
    let mut got = vec![];
    for name in ["flat_wind", "heated_slope"] {
        let c = load(name);
        let st = api::solve(&c, &opts(None, None)).unwrap().state;
        got.push(fnv(&api::solve(&c, &opts(Some(st.clone()), None)).unwrap()));
        got.push(fnv(&api::solve(&c, &opts(Some(st), Some(4))).unwrap()));
    }
    let want: [u64; 4] = [
        0x0fa2_fad6_92d9_154c,
        0xc8c0_4236_4d70_699f,
        0x0553_fb64_c3a4_4daf,
        0xdf73_6661_b3c6_c836,
    ];
    assert_eq!(got, want);
}
