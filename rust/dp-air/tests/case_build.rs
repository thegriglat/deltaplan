//! RW-6e: сборка случая решателя (`build_solver_case`) против буферов игры после `K_SETUP`
//! (`air_picard.glsl`, GPU) и решение Пикаром на собранном случае. Дамп:
//! `tools/research/rust_wind/dump_case_build.sh` (rust/dp-air/tests/data/case_build): вход ядра
//! (`col`, `lev`, `prm` после `prepare`) и 11 буферов (`tcode`, `ubu`, `ubv`, `spu`, `spw`, `spc`,
//! `kbg`, `Q`, `Kx`, `Ky`, `Kz`) — целиком у синтетики 1200 м, выборкой с шагом `stride` и хешем
//! FNV-1a слов f32 у Онгудая 400 м.
//!
//! Типы (`tcode`) обязаны совпасть точно; остальное — отн. к max|эталон| ≤ 1e-6 (GPU считает
//! `pow`/`sqrt` своей тригонометрией, `fma`); достигнутое печатается (`--nocapture`).
//! Решение: синтетика 1200 м — сходится (обычный прогон); Онгудай 400 м, tol_scale 5 — `#[ignore]`,
//! только release: `cargo test --release -p dp-air --test case_build -- --ignored --nocapture`.
use dp_air::field::case_build::{SolverCfg, build_solver_case};
use dp_air::field::case_prepare::{CaseParams, NCOL, NLEV, NPRM, PreparedPlanes};
use picard_rs::api::{SolveOpts, StopReason, solve};
use picard_rs::case::Case;
use serde_json::Value;
use std::path::PathBuf;

const TOL: f64 = 1e-6;

struct Dump {
    meta: Value,
    bin: Vec<u8>,
}

impl Dump {
    fn load() -> Dump {
        let d = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/data/case_build");
        let meta =
            serde_json::from_str(&std::fs::read_to_string(d.join("build.json")).unwrap()).unwrap();
        let bin = std::fs::read(d.join("build.bin")).unwrap();
        Dump { meta, bin }
    }
    fn f32s(&self, k: &str) -> Vec<f32> {
        let a = &self.meta["arrays"][k];
        assert_eq!(a["dtype"], "f32", "{k}");
        let (o, n) = (
            a["offset"].as_u64().unwrap() as usize,
            a["count"].as_u64().unwrap() as usize,
        );
        self.bin[o..o + 4 * n]
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn case(&self, tag: &str) -> &Value {
        self.meta["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["tag"] == tag)
            .unwrap_or_else(|| panic!("нет случая {tag}"))
    }
}

fn planes_of(d: &Dump, c: &Value) -> PreparedPlanes {
    let tag = c["tag"].as_str().unwrap();
    let (nx, ny, nz) = (
        c["nx"].as_u64().unwrap() as usize,
        c["ny"].as_u64().unwrap() as usize,
        c["nz"].as_u64().unwrap() as usize,
    );
    let col = d.f32s(&format!("{tag}/col"));
    let lev = d.f32s(&format!("{tag}/lev"));
    let prm: [f32; NPRM] = d.f32s(&format!("{tag}/prm")).try_into().unwrap();
    assert_eq!(col.len(), NCOL * (nx + 2) * (ny + 2));
    assert_eq!(lev.len(), NLEV * (nz + 2));
    let f = |k: &str| c[k].as_f64().unwrap();
    PreparedPlanes {
        nx,
        ny,
        nz,
        nx_h: nx + 2,
        ny_h: ny + 2,
        nz_h: nz + 2,
        x0: f("x0"),
        y0: f("y0"),
        dx: f("dx"),
        dz: f("dz"),
        z_bot: f("z_bot"),
        col,
        lev,
        prm,
        kf: Vec::new(),
        n_unk: [0; 4],
        n_fluid: 0,
        cd: f("cd"),
        fixed_scale: f64::from(prm[16]),
        ustar: 0.0,
        u_a: f("u_a"),
        ex: 0.0,
        ey: 0.0,
        z_sat: f64::from(prm[12]),
        z0: f("z0"),
        alpha: f64::from(prm[13]),
        h_mech: 0.0,
        wstar_max: 0.0,
        h_max: 0.0,
        heat_used: Vec::new(),
    }
}

fn build(d: &Dump, tag: &str) -> (PreparedPlanes, Case) {
    let c = d.case(tag);
    let pl = planes_of(d, c);
    let case = build_solver_case(
        &pl,
        &CaseParams::default(),
        &SolverCfg::new(c["u10"].as_f64().unwrap()),
    )
    .unwrap();
    (pl, case)
}

fn fnv(a: &[f32]) -> u64 {
    a.iter().fold(0xcbf2_9ce4_8422_2325u64, |h, x| {
        (h ^ u64::from(x.to_bits())).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// Буферы игры, как их получает Rust-случай: `tcode`, `ubu` (на гранях типа 2 — жёсткие значения),
/// `ubv`, `spu`, `spw`, `spc`, `kbg`, `Q`, `Kx`, `Ky`, `Kz`.
fn game_buffers(c: &Case) -> Vec<(&'static str, Vec<f32>)> {
    let a = |k: &str| c.arr(k).unwrap().clone();
    let r = |k: &str| c.arr(k).unwrap();
    let (cell, tu, tv, tw) = (r("cell"), r("tu"), r("tv"), r("tw"));
    let tcode: Vec<f32> = (0..c.n3())
        .map(|q| cell[q] + 4.0 * tu[q] + 16.0 * tv[q] + 64.0 * tw[q])
        .collect();
    let scatter = |bg: &str, idx: &str, val: &str| {
        let mut v = a(bg);
        for (b, f) in a(idx).iter().zip(a(val)) {
            v[*b as usize] = f;
        }
        v
    };
    vec![
        ("tcode", tcode),
        ("ubu", scatter("ubg", "b_u", "fixed_u")),
        ("ubv", scatter("vbg", "b_v", "fixed_v")),
        ("spu", a("sp_u")),
        ("spw", a("sp_w")),
        ("spc", a("spc")),
        ("kbg", a("nu_bg")),
        ("Q", a("Q")),
        ("Kx", a("Kx")),
        ("Ky", a("Ky")),
        ("Kz", a("Kz")),
    ]
}

/// Сверка с дампом одного случая: возвращает худшую отн. ошибку (к max|эталон|) по буферам.
fn compare(d: &Dump, tag: &str) -> f64 {
    let (_, case) = build(d, tag);
    let c = d.case(tag);
    let full = c["full"].as_bool().unwrap();
    let stride = d.meta["stride"].as_u64().unwrap() as usize;
    let mut worst = 0.0f64;
    for (name, mine) in game_buffers(&case) {
        let want = d.f32s(&format!("{tag}/{name}"));
        let got: Vec<f32> = if full {
            mine.clone()
        } else {
            mine.iter().step_by(stride).copied().collect()
        };
        assert_eq!(got.len(), want.len(), "{tag}/{name}: длина");
        let scale = want
            .iter()
            .fold(0.0f64, |m, &x| m.max(f64::from(x).abs()))
            .max(1e-30);
        let mut maxd = 0.0f64;
        let mut ndiff = 0usize;
        for (a, b) in got.iter().zip(&want) {
            if a.to_bits() != b.to_bits() {
                ndiff += 1;
                maxd = maxd.max((f64::from(*a) - f64::from(*b)).abs());
            }
        }
        let hash_ok = (fnv(&mine) as i64).to_string() == c["hashes"][name].as_str().unwrap();
        println!(
            "{tag}/{name}: не побитно {ndiff}/{}, max|Δ|/max|ref| = {:.2e}, хеш всего буфера {}",
            got.len(),
            maxd / scale,
            if hash_ok { "совпал" } else { "иной" }
        );
        if name == "tcode" {
            assert_eq!(ndiff, 0, "{tag}: типы клеток и граней — точно");
        }
        worst = worst.max(maxd / scale);
    }
    assert!(worst <= TOL, "{tag}: {worst:.3e} > {TOL:e}");
    worst
}

#[test]
fn k_setup_synthetic_1200_heat() {
    compare(&Dump::load(), "synthetic_1200_heat");
}

#[test]
fn k_setup_synthetic_1200_mech() {
    compare(&Dump::load(), "synthetic_1200_mech");
}

#[test]
fn k_setup_synthetic_1200_calm() {
    // u10 = 0: жёсткая граница нулевая, фона нет
    let d = Dump::load();
    compare(&d, "synthetic_1200_heat_calm");
    let (_, case) = build(&d, "synthetic_1200_heat_calm");
    assert!(case.arr("fixed_u").unwrap().iter().all(|&x| x == 0.0));
    assert!(case.arr("ubg").unwrap().iter().all(|&x| x == 0.0));
}

#[test]
fn k_setup_ongudai_400_heat() {
    compare(&Dump::load(), "ongudai_400_heat");
}

#[test]
fn k_setup_ongudai_400_mech() {
    compare(&Dump::load(), "ongudai_400_mech");
}

/// Свойства собранного случая (T2): непротекание и согласие индексов граней с типами, порядок
/// `b_u/b_v`, конечность, Q только у нагретого.
#[test]
fn built_case_properties() {
    let d = Dump::load();
    for tag in [
        "synthetic_1200_heat",
        "synthetic_1200_mech",
        "ongudai_400_heat",
    ] {
        let (pl, case) = build(&d, tag);
        let n3 = case.n3();
        for (name, v) in &case.arrays {
            assert!(v.iter().all(|x| x.is_finite()), "{tag}/{name}: не конечны");
        }
        assert_eq!(n3, pl.nx_h * pl.ny_h * pl.nz_h);
        assert_eq!(case.arr("hc").unwrap().len(), pl.nx * pl.ny);
        assert_eq!(case.arr("gam").unwrap().len(), pl.nz_h);
        assert_eq!(case.arr("lam").unwrap().len(), pl.nx_h * pl.ny_h);
        let tu = case.arr("tu").unwrap();
        for (key, t) in [("b_u", tu), ("b_v", case.arr("tv").unwrap())] {
            let b = case.arr(key).unwrap();
            assert!(b.windows(2).all(|w| w[0] < w[1]), "{key}: порядок");
            assert_eq!(b.len(), t.iter().filter(|&&x| x == 2.0).count());
            assert!(b.iter().all(|&i| t[i as usize] == 2.0));
        }
        // грань-неизвестная имеет проводимость, остальные — нулевую
        let kx = case.arr("Kx").unwrap();
        for q in 0..n3 {
            assert_eq!(kx[q] > 0.0, tu[q] == 1.0, "{tag}: Kx при tu={}", tu[q]);
        }
        // непротекание: на гранях-стенках фона нет
        let ubg = case.arr("ubg").unwrap();
        assert!((0..n3).all(|q| tu[q] != 0.0 || ubg[q] == 0.0));
        let heated = case.arr("Q").unwrap().iter().any(|&x| x != 0.0);
        assert_eq!(
            heated,
            tag.ends_with("heat") || tag == "ongudai_400_heat",
            "{tag}: Q"
        );
        assert!(case.solution.is_none() && !case.has_reference());
    }
}

fn run_solve(tag: &str, tol_scale: f64) -> (usize, StopReason, f64) {
    let d = Dump::load();
    let (_, case) = build(&d, tag);
    let opts = SolveOpts {
        threads: 0,
        tol_scale,
        max_iters: 400,
        ..SolveOpts::default()
    };
    let s = solve(&case, &opts).unwrap();
    assert!(s.dev.is_none(), "случай без эталона: dev = None");
    let finite = [&s.state.u, &s.state.v, &s.state.w, &s.state.th, &s.state.p]
        .iter()
        .all(|a| a.iter().all(|x| x.is_finite()));
    assert!(finite, "{tag}: поле конечно");
    let vmax = s
        .state
        .u
        .iter()
        .chain(&s.state.v)
        .fold(0.0f32, |m, x| m.max(x.abs()));
    println!(
        "{tag}: iters {}, {:?}, mom_rms {:.2e}, max|u,v| {vmax:.2} м/с",
        s.iters, s.stop, s.residuals.mom_rms
    );
    (s.iters, s.stop, f64::from(vmax))
}

#[test]
fn solve_synthetic_1200_converges() {
    let (it, stop, vmax) = run_solve("synthetic_1200_heat", 5.0);
    assert_eq!(stop, StopReason::Converged);
    assert!(it > 0 && it < 400);
    assert!(vmax > 0.1 && vmax < 40.0, "скорость {vmax}");
}

#[test]
fn solve_synthetic_1200_calm_converges() {
    let (_, stop, _) = run_solve("synthetic_1200_heat_calm", 5.0);
    assert_eq!(stop, StopReason::Converged);
}

/// Ориентир AP-20 (rust/picard_rs/out/final): u3_heat, tol_scale 5 — ~111 итераций; здесь ветер
/// меню и сезон другие, поэтому диапазон широкий. Release.
#[test]
#[ignore = "долго в dev-профиле: cargo test --release -p dp-air --test case_build -- --ignored --nocapture"]
fn solve_ongudai_400_heat() {
    let (it, stop, vmax) = run_solve("ongudai_400_heat", 5.0);
    assert_eq!(stop, StopReason::Converged);
    assert!((30..=300).contains(&it), "итерации {it}");
    assert!(vmax > 0.5 && vmax < 40.0);
}

#[test]
#[ignore = "долго в dev-профиле: cargo test --release -p dp-air --test case_build -- --ignored --nocapture"]
fn solve_ongudai_400_mech() {
    let (_, stop, _) = run_solve("ongudai_400_mech", 5.0);
    assert_eq!(stop, StopReason::Converged);
}
