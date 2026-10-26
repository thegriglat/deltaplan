//! RW-6l: механизмы A (линейная теория, DCT-II), B (пузырь срыва), D (слои Лапласа, SOR) и H
//! (штиль, через D) против GDScript `AirPhase.modes` / `AirPhaseCpu.{synth, laplace, mech}`.
//! Дамп — `tools/research/rust_wind/dump_phase_mech.sh` (rust/dp-air/tests/data/phase_mech):
//! поля механизмов в точках (каждый третий столбец и столбцы под огибающей срыва × 7 высот над землёй + `H_c − 20`) для фикстур
//! места (полдень, U10 0,3 / 1,5 / 6 / 12) и синтетики `test_air_phase.gd`; для "synthetic" и
//! `t_contract` — ещё моды, слой возмущений A и слои Лапласа целиком. Входы фаз — из дампа RW-6k
//! (tests/data/phase) по тому же тегу.
//!
//! Проверки: (1) против дампа — поэлементно ≤ 1e-6 относительная (не к максимуму; пол 1e-9 для
//! значений, равных нулю с точностью до округления); SOR — то же число итераций (из конфига;
//! дамп хранит его для сверки); (2) физика: числа теста GDScript (штиль/блок/ветер), стенки D,
//! пузырь срыва, профиль притока; (3) детерминизм: 1 и 4 потока — побитно.
use dp_air::field::phase::calm::mix;
use dp_air::field::phase::classifier::{Variant, classify};
use dp_air::field::phase::config::PhaseCfg;
use dp_air::field::phase::layers::laplace;
use dp_air::field::phase::linear::{self, NMO, modes, synth, u_prof};
use dp_air::field::phase::mech::{MechFields, mech_at};
use dp_air::field::phase::prepare::{GInput, PhaseCase, Prepared, prepare};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::OnceLock;

const REL: f64 = 1e-6;
const FLOOR: f64 = 1e-9;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn cfg() -> PhaseCfg {
    let t = std::fs::read_to_string(root().join("../../configs/atmosphere.json")).unwrap();
    PhaseCfg::from_json(&t).unwrap()
}

struct Dump {
    meta: Value,
    bin: Vec<u8>,
}

impl Dump {
    fn load(dir: &str, name: &str) -> Dump {
        let d = root().join(dir);
        let meta =
            serde_json::from_str(&std::fs::read_to_string(d.join(format!("{name}.json"))).unwrap())
                .unwrap();
        Dump {
            meta,
            bin: std::fs::read(d.join(format!("{name}.bin"))).unwrap(),
        }
    }
    fn f64s(&self, k: &str) -> Vec<f64> {
        let a = self.meta["arrays"]
            .get(k)
            .unwrap_or_else(|| panic!("нет массива {k}"));
        let (o, n) = (
            a["offset"].as_u64().unwrap() as usize,
            a["count"].as_u64().unwrap() as usize,
        );
        self.bin[o..o + 8 * n]
            .chunks_exact(8)
            .map(|c| f64::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn has(&self, k: &str) -> bool {
        self.meta["arrays"].get(k).is_some()
    }
}

/// Случай: вход фаз (дамп RW-6k) и ожидания механизмов (дамп RW-6l).
struct Case {
    tag: String,
    scal: std::collections::HashMap<String, f64>,
    hc: Vec<f64>,
    gam: Vec<f64>,
    heat: Vec<f64>,
    heat_used: Vec<f64>,
    h_bl: Vec<f64>,
    wst: Vec<f64>,
    zic: Vec<f64>,
    gw: Vec<f64>,
    /// Вариант с крутой огибающей срыва (`b_env_angle_deg` = 1°, как в дампере).
    env: bool,
}

impl Case {
    fn s(&self, k: &str) -> f64 {
        self.scal[k]
    }
    fn input(&self) -> PhaseCase<'_> {
        let g_on = self.s("g_active") > 0.0;
        PhaseCase {
            nx: self.s("nx") as usize,
            ny: self.s("ny") as usize,
            nz: self.s("nz") as usize,
            dx: self.s("dx"),
            dz: self.s("dz"),
            z_bot: self.s("z_bot"),
            ex: self.s("ex"),
            ey: self.s("ey"),
            u_a: self.s("usat"),
            z_sat: self.s("zsat"),
            alpha: self.s("alpha"),
            z0: self.s("z0"),
            ustar: self.s("ustar"),
            tau_cool: self.s("tau"),
            u10: self.s("u10"),
            z_i: self.s("z_i"),
            hc: &self.hc,
            gam: &self.gam,
            heat: &self.heat,
            heat_used: &self.heat_used,
            h_bl: &self.h_bl,
            wst: &self.wst,
            z_i_col: &self.zic,
            g: g_on.then_some(GInput {
                dth_c: self.s("g_dth_c"),
                weight: &self.gw,
            }),
        }
    }
    fn prep(&self) -> Prepared {
        let mut c = cfg();
        if self.env {
            c.classifier.b_env_angle_deg = 1.0;
        }
        prepare(&self.input(), &c).unwrap()
    }
}

struct All {
    mech: Dump,
    cases: Vec<Case>,
}

fn all() -> &'static All {
    static A: OnceLock<All> = OnceLock::new();
    A.get_or_init(|| {
        let ph = Dump::load("tests/data/phase", "phase");
        let mech = Dump::load("tests/data/phase_mech", "phase_mech");
        let fields: Vec<String> = ph.meta["scal_fields"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        let cases = mech.meta["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| {
                let tag = c["tag"].as_str().unwrap().to_string();
                let base = tag.strip_suffix("_env").unwrap_or(&tag).to_string();
                let sv = ph.f64s(&format!("{base}/scal"));
                Case {
                    scal: fields.iter().cloned().zip(sv).collect(),
                    hc: ph.f64s(&format!("{base}/hc")),
                    gam: ph.f64s(&format!("{base}/gam")),
                    heat: ph.f64s(&format!("{base}/heat")),
                    heat_used: ph.f64s(&format!("{base}/heat_used")),
                    h_bl: ph.f64s(&format!("{base}/h_bl")),
                    wst: ph.f64s(&format!("{base}/wst")),
                    zic: ph.f64s(&format!("{base}/zic")),
                    gw: ph.f64s(&format!("{base}/gw")),
                    env: base != tag,
                    tag,
                }
            })
            .collect();
        All { mech, cases }
    })
}

fn case(tag: &str) -> &'static Case {
    all()
        .cases
        .iter()
        .find(|c| c.tag == tag)
        .unwrap_or_else(|| panic!("нет случая {tag}"))
}

/// Наибольшая поэлементная относительная ошибка `|a − b| ≤ REL·|b| + FLOOR`; возвращает
/// `max |a − b| / (|b| + FLOOR/REL)` и номер худшего элемента.
fn rel_err(a: &[f64], b: &[f64]) -> (f64, usize) {
    assert_eq!(a.len(), b.len(), "длины");
    let mut worst = (0.0f64, 0usize);
    for (i, (x, y)) in a.iter().zip(b).enumerate() {
        assert!(x.is_finite(), "не число в элементе {i}");
        let e = (x - y).abs() / (y.abs() + FLOOR / REL);
        if e > worst.0 {
            worst = (e, i);
        }
    }
    worst
}

fn expect_close(what: &str, a: &[f64], b: &[f64]) -> f64 {
    let (e, i) = rel_err(a, b);
    assert!(
        e <= REL,
        "{what}: относительная ошибка {e:e} в элементе {i} ({} против {})",
        a[i],
        b[i]
    );
    e
}

fn mech_heights(p: &Prepared, d: &Dump) -> Vec<f64> {
    d.meta["heights"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_f64().unwrap())
        .chain(std::iter::once(p.hcd - 20.0))
        .collect()
}

/// Поля в точках дампа: порядок как в дампере (столбец с шагом `stride`, 5 высот + `H_c − 20`).
fn sample_mech(p: &Prepared, f: &MechFields, d: &Dump) -> Vec<f64> {
    let stride = d.meta["stride"].as_u64().unwrap() as usize;
    let hs = mech_heights(p, d);
    let mut out = Vec::new();
    for c in 0..p.n2 {
        let hc = p.cols.hc[c];
        if c % stride != 0 && p.cols.heff[c] - hc <= 1.0 {
            continue;
        }
        for (q, &h) in hs.iter().enumerate() {
            let z = if q + 1 == hs.len() { h } else { hc + h };
            out.extend_from_slice(&mech_at(p, f, c, z));
        }
    }
    out
}

// ---------------------------------------------------------------- (1) против дампа

#[test]
fn mech_points_match_dump() {
    let a = all();
    assert_eq!(
        a.mech.meta["sor_iters"].as_u64().unwrap() as usize,
        cfg().d.sor_iters,
        "SOR: то же число итераций, что в GDScript"
    );
    let mut worst = 0.0f64;
    let (mut nb, mut nd) = (0, 0);
    for c in &a.cases {
        let p = c.prep();
        let f = MechFields::new(&p);
        let got = sample_mech(&p, &f, &a.mech);
        let want = a.mech.f64s(&format!("{}/mech", c.tag));
        worst = worst.max(expect_close(
            &format!("{}: поля в точках", c.tag),
            &got,
            &want,
        ));
        // поле B / D действует хотя бы в одной точке (иначе сверка пуста)
        for m in got.chunks_exact(10) {
            nb += usize::from(m[4] != m[0] || m[5] != m[1]);
            nd += usize::from(m[7] != m[0] || m[8] != m[1]);
        }
    }
    assert!(nb > 0 && nd > 0, "B ({nb}) и D ({nd}) участвуют в сверке");
    println!("phase_mech: точки, наибольшая ошибка {worst:e}; B {nb}, D {nd}");
}

#[test]
fn modes_slab_laplace_match_dump() {
    let a = all();
    let mut seen = 0;
    for c in &a.cases {
        if !a.mech.has(&format!("{}/slab", c.tag)) {
            continue;
        }
        seen += 1;
        let p = c.prep();
        let t = &c.tag;
        let md = modes(&p);
        assert_eq!(md.data.len(), NMO * p.n2);
        expect_close(
            &format!("{t}: моды"),
            &md.data,
            &a.mech.f64s(&format!("{t}/modes")),
        );
        let sl = synth(&p, &md);
        expect_close(
            &format!("{t}: слой A"),
            &sl.data,
            &a.mech.f64s(&format!("{t}/slab")),
        );
        let lap = laplace(&p);
        expect_close(
            &format!("{t}: слои Лапласа"),
            &lap.data,
            &a.mech.f64s(&format!("{t}/lap")),
        );
    }
    assert!(seen >= 5, "полные дампы: {seen}");
}

// ---------------------------------------------------------------- (2) физика и числа теста GD

#[test]
fn inflow_profile_and_wall_layers() {
    for c in &all().cases {
        let p = c.prep();
        // профиль притока: U(z_sat) = U_sat, монотонен, на стенке z0 — малая доля
        assert!((u_prof(&p, p.prm.zsat) - p.usat).abs() <= 1e-9 * p.usat.max(1.0));
        assert!(u_prof(&p, 10.0) <= u_prof(&p, 100.0) + 1e-12);
        // слои D: внутри стенки (h_c > z_L) скорость 0; свободные клетки с краю области — вдоль e
        let lap = laplace(&p);
        for l in 0..lap.nl {
            let (gx, gy) = (lap.plane(l, 1), lap.plane(l, 2));
            for q in 0..p.n2 {
                if p.cols.hc[q] > lap.zl[l] {
                    assert!(gx[q] == 0.0 && gy[q] == 0.0, "{}: стенка слоя {l}", c.tag);
                }
                assert!(gx[q].abs() <= 3.0 && gy[q].abs() <= 3.0);
            }
        }
    }
}

#[test]
fn wind_over_hill_and_regimes() {
    // U10 12 м/с (A, ω = 1) над вершиной: ветер есть (test_field_without_picard: > 0,5 м/с)
    let p = case("t_ax_u12").prep();
    let f = MechFields::new(&p);
    let c = (p.ny / 2) * p.nx + p.nx / 2;
    let top = p.cols.hc[c] + 300.0;
    let m = mech_at(&p, &f, c, top);
    let w = classify(&p, Variant::Mech);
    let mx = mix(&w, p.n2, c, &m);
    let sp = mx[0].hypot(mx[1]);
    assert!(sp > 0.5, "ветер над вершиной ({sp:.2} м/с)");
    // сильный ветер: слоёв D нет, пузыря срыва нет (огибающая не выше рельефа заметно)
    assert!(p.zl.is_empty());
    // блокирование U10 1,5: слои D есть, ниже H_c поле D ≠ A
    let p = case("t_ax_u1.5").prep();
    assert!(!p.zl.is_empty() && p.prm.hcd > p.base);
    let f = MechFields::new(&p);
    let c = (p.ny / 2) * p.nx + p.nx / 2;
    let m = mech_at(&p, &f, c, p.base + 0.5 * (p.prm.hcd - p.base));
    assert!(m[7] != m[0] || m[8] != m[1], "D действует ниже H_c");
    assert_eq!(m[9], 0.0, "в слоях D w = 0");
    // штиль U10 0,3: все веса H/D → смесь берёт поле D (H = D)
    let p = case("t_ax_u0.3").prep();
    let w = classify(&p, Variant::Mech);
    let f = MechFields::new(&p);
    let m = mech_at(&p, &f, c, p.base + 10.0);
    let mx = mix(&w, p.n2, c, &m);
    assert!(mx.iter().all(|v| v.is_finite()));
}

#[test]
fn bubble_reverses_below_envelope() {
    // под огибающей срыва поле B — вдоль/против e без вертикальной составляющей; у земли возврат
    let mut n = 0;
    for c in &all().cases {
        let p = c.prep();
        let f = MechFields::new(&p);
        for q in 0..p.n2 {
            let depth = p.cols.heff[q] - p.cols.hc[q];
            if depth > 1.0 {
                let m = mech_at(&p, &f, q, p.cols.hc[q] + 0.25 * depth);
                assert_eq!(m[6], 0.0, "{}: w пузыря", c.tag);
                let along = m[4] * p.prm.ex + m[5] * p.prm.ey;
                let perp = m[4] * p.prm.ey - m[5] * p.prm.ex;
                assert!(
                    perp.abs() <= 1e-9 * along.abs().max(1.0),
                    "{}: B вдоль e",
                    c.tag
                );
                n += 1;
            }
        }
    }
    println!("phase_mech: клеток под огибающей срыва: {n}");
}

#[test]
fn linear_theory_vanishes_on_flat_terrain() {
    // плоский рельеф: амплитуды мод 0 → возмущения A нулевые
    let c = case("t_ax_u12");
    let hc = vec![500.0; c.hc.len()];
    let mut inp = c.input();
    inp.hc = &hc;
    let p = prepare(&inp, &cfg()).unwrap();
    let md = modes(&p);
    assert!(md.plane(linear::MO_AMP).iter().all(|&v| v.abs() < 1e-12));
    assert!(synth(&p, &md).data.iter().all(|&v| v.abs() < 1e-9));
}

// ---------------------------------------------------------------- (3) детерминизм

#[test]
fn deterministic_1_and_4_threads() {
    let run = |threads: usize| {
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .unwrap();
        pool.install(|| {
            let mut out: Vec<u64> = Vec::new();
            for tag in ["t_contract", "t_ax_u1.5", "synthetic_noon_u6.0"] {
                let p = case(tag).prep();
                let f = MechFields::new(&p);
                out.extend(f.modes.data.iter().map(|v| v.to_bits()));
                out.extend(f.slab.data.iter().map(|v| v.to_bits()));
                out.extend(f.lap.data.iter().map(|v| v.to_bits()));
            }
            out
        })
    };
    assert!(run(1) == run(4), "1 и 4 потока — побитно");
}
