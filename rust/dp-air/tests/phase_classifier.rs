//! RW-6k: фазы поля 1 (подготовка и классификатор) против GDScript `AirPhase`/`AirPhaseCpu`.
//! Дамп — `tools/research/rust_wind/dump_phase.sh` (rust/dp-air/tests/data/phase): растры фикстур
//! места (synthetic, ongudai), U10 0,3/1,5/6/12 м/с, полдень и вечер, и синтетические случаи
//! `tests/atmosphere/test_air_phase.gd`.
//!
//! Проверки: (1) числа теста GDScript (Σ весов = 1, оси U10 0,3/1,5/12, пороги из конфига);
//! (2) против дампа: числа prepare, плоскости, веса ≤ 1e-6, маски побитно, ω ≤ 1e-6;
//! (3) детерминизм: 1 и 4 потока — побитно.
use dp_air::field::phase::classifier::{
    PhaseMaps, Variant, classify, classify_pair, frozen_fraction, phase_fractions,
};
use dp_air::field::phase::config::{DStrongAxis, PhaseCfg};
use dp_air::field::phase::prepare::{GInput, K, PHASES, PhaseCase, Prepared, prepare};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::OnceLock;

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
    fn load() -> Dump {
        let d = root().join("tests/data/phase");
        let meta =
            serde_json::from_str(&std::fs::read_to_string(d.join("phase.json")).unwrap()).unwrap();
        Dump {
            meta,
            bin: std::fs::read(d.join("phase.bin")).unwrap(),
        }
    }
    fn slice(&self, k: &str, w: usize) -> (&[u8], usize) {
        let a = self.meta["arrays"]
            .get(k)
            .unwrap_or_else(|| panic!("нет массива {k}"));
        let (o, n) = (
            a["offset"].as_u64().unwrap() as usize,
            a["count"].as_u64().unwrap() as usize,
        );
        (&self.bin[o..o + w * n], n)
    }
    fn f64s(&self, k: &str) -> Vec<f64> {
        self.slice(k, 8)
            .0
            .chunks_exact(8)
            .map(|c| f64::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn u8s(&self, k: &str) -> Vec<u8> {
        self.slice(k, 1).0.to_vec()
    }
    fn has(&self, k: &str) -> bool {
        self.meta["arrays"].get(k).is_some()
    }
}

/// Случай дампа: вход prepare и ожидания GDScript.
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
    d: &'static Dump,
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
        prepare(&self.input(), &cfg()).unwrap()
    }
    fn prep_cfg(&self, c: &PhaseCfg) -> Prepared {
        prepare(&self.input(), c).unwrap()
    }
}

fn cases() -> &'static Vec<Case> {
    static D: OnceLock<Dump> = OnceLock::new();
    static C: OnceLock<Vec<Case>> = OnceLock::new();
    C.get_or_init(|| {
        let d: &'static Dump = D.get_or_init(Dump::load);
        let fields: Vec<String> = d.meta["scal_fields"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        d.meta["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| {
                let tag = c["tag"].as_str().unwrap().to_string();
                let sv = d.f64s(&format!("{tag}/scal"));
                Case {
                    scal: fields.iter().cloned().zip(sv).collect(),
                    hc: d.f64s(&format!("{tag}/hc")),
                    gam: d.f64s(&format!("{tag}/gam")),
                    heat: d.f64s(&format!("{tag}/heat")),
                    heat_used: d.f64s(&format!("{tag}/heat_used")),
                    h_bl: d.f64s(&format!("{tag}/h_bl")),
                    wst: d.f64s(&format!("{tag}/wst")),
                    zic: d.f64s(&format!("{tag}/zic")),
                    gw: d.f64s(&format!("{tag}/gw")),
                    tag,
                    d,
                }
            })
            .collect()
    })
}

fn case(tag: &str) -> &'static Case {
    cases()
        .iter()
        .find(|c| c.tag == tag)
        .unwrap_or_else(|| panic!("нет случая {tag}"))
}

fn max_abs(a: &[f64], b: &[f64]) -> f64 {
    assert_eq!(a.len(), b.len());
    a.iter()
        .zip(b)
        .map(|(x, y)| (x - y).abs())
        .fold(0.0, f64::max)
}

fn close(a: f64, b: f64, tol: f64, what: &str) {
    assert!(
        (a - b).abs() <= tol * b.abs().max(1.0),
        "{what}: {a} против {b}"
    );
}

// ---------------------------------------------------------------- (2) против дампа

#[test]
fn prepare_numbers_match_dump() {
    assert!(cases().len() >= 24);
    for c in cases() {
        let p = c.prep();
        let t = &c.tag;
        let num = |k: &str, v: f64| close(v, c.s(k), 1e-9, &format!("{t}: {k}"));
        num("n_bv", p.n_bv);
        num("fr", p.fr);
        num("n_eff", p.n_eff);
        num("zi", p.zi);
        num("gamw", p.gamw);
        num("zi_agl", p.zi_agl);
        num("hcd", p.hcd);
        num("base", p.base);
        num("nl", p.zl.len() as f64);
        num("b_fr", p.b_fr);
        num("b_u", p.b_u);
        num("omega", p.omega);
        num("w_h", p.w_h);
        num("w_ds", p.w_ds);
        num("w_d", p.w_d);
        num("u_over_n", p.u_over_n);
        num("shadow_frac", p.shadow_frac);
        num("relief", p.relief);
        num("hmin", p.hmin);
        assert_eq!(f64::from(u8::from(p.full)), c.s("full"), "{t}: full");
        assert_eq!(f64::from(u8::from(p.heated)), c.s("heated"), "{t}: heated");
        let zl = c.d.f64s(&format!("{t}/zl"));
        assert!(max_abs(&p.zl, &zl) <= 1e-9, "{t}: слои D");
        // ω: однородная карта (f32 как в игре), допуск 1e-6
        let om = p.omega_map();
        assert_eq!(om.len(), p.n2);
        assert!(
            om.iter()
                .all(|&o| (f64::from(o) - c.s("omega")).abs() <= 1e-6)
        );
        // плоскости (только где дамп их несёт)
        if c.d.has(&format!("{t}/col_heff")) {
            let planes: [(&str, &[f64]); 9] = [
                ("heff", &p.cols.heff),
                ("t", &p.cols.t),
                ("s", &p.cols.s),
                ("gx", &p.cols.gx),
                ("gy", &p.cols.gy),
                ("sal", &p.cols.sal),
                ("zi", &p.cols.zi),
                ("heat", &p.cols.heat),
                ("hk", &p.cols.hk),
            ];
            for (name, v) in planes {
                let want = c.d.f64s(&format!("{t}/col_{name}"));
                let e = max_abs(v, &want);
                assert!(e <= 1e-9, "{t}: плоскость {name}, ошибка {e}");
            }
        }
    }
}

#[test]
fn weights_and_masks_match_dump() {
    let mut worst = 0.0f64;
    for c in cases() {
        let p = c.prep();
        let t = &c.tag;
        for (v, wk, fk) in [
            (Variant::Heat, "w_h", "frz_h"),
            (Variant::Mech, "w_m", "frz_m"),
        ] {
            let r = classify(&p, v);
            let want = c.d.f64s(&format!("{t}/{wk}"));
            let e = max_abs(&r.weights, &want);
            worst = worst.max(e);
            assert!(e <= 1e-6, "{t}/{wk}: веса, ошибка {e}");
            assert_eq!(r.freeze, c.d.u8s(&format!("{t}/{fk}")), "{t}/{fk}: маска");
            assert_eq!(r.freeze.len(), p.n2);
        }
    }
    println!("phase_classifier: наибольшее расхождение весов {worst:e}");
}

// ---------------------------------------------------------------- (1) числа test_air_phase.gd

fn sum_check(p: &Prepared, w: &[f64], tol: f64) -> f64 {
    let n2 = p.n2;
    let mut worst = 0.0f64;
    for c in 0..n2 {
        let mut s = 0.0;
        for k in 0..K {
            assert!(w[k * n2 + c] >= -tol, "вес ≥ 0");
            s += w[k * n2 + c];
        }
        worst = worst.max((s - 1.0).abs());
    }
    assert!(worst <= tol, "|Σ w − 1| = {worst:e} ≤ {tol}");
    worst
}

#[test]
fn sum_of_weights_is_one() {
    for c in cases() {
        let p = c.prep();
        let m = classify_pair(&p);
        sum_check(&p, &m.heat.weights, 1e-5);
        sum_check(&p, &m.mech.weights, 1e-5);
        assert_eq!(m.heat.weights.len(), K * p.n2);
    }
}

fn leading(p: &Prepared, w: &[f64]) -> (&'static str, f64) {
    let fr = phase_fractions(w, p.n2);
    let (mut best, mut bv) = ("", -1.0);
    for k in 0..K {
        if fr[k] > bv {
            bv = fr[k];
            best = PHASES[k];
        }
    }
    (best, bv)
}

#[test]
fn phase_axes_u10() {
    // штиль → H, блокирование → D (сильное D — механизм, ω = 0,5), сильный ветер → A без заморозки
    for (tag, want, frozen) in [
        ("t_ax_u0.3", "H", true),
        ("t_ax_u1.5", "D", true),
        ("t_ax_u12", "A", false),
    ] {
        let c = case(tag);
        let p = c.prep();
        let r = classify(&p, Variant::Heat);
        let (best, bv) = leading(&p, &r.weights);
        let fz = frozen_fraction(&r.freeze);
        println!(
            "U10 {} → Fr {:.2}, фаза {best} ({bv:.2}), ω {:.2}, заморожено {fz:.2}",
            c.s("u10"),
            p.fr,
            p.omega
        );
        assert_eq!(best, want, "{tag} (Fr {:.2})", p.fr);
        assert_eq!(fz > 0.99, frozen, "{tag}: заморозка всей области");
    }
    let p = case("t_ax_u1.5").prep();
    assert!(
        (p.omega - 0.5).abs() < 0.05,
        "ω у границ ≈ 0,5 ({})",
        p.omega
    );
}

#[test]
fn thresholds_from_config() {
    let c = case("t_ax_u12");
    let mut conf = cfg();
    conf.classifier.h_c = 1000.0;
    let p = c.prep_cfg(&conf);
    let w = classify(&p, Variant::Heat).weights;
    let h = phase_fractions(&w, p.n2)[6];
    assert!(h > 0.9, "h_c из конфига → H ({h:.2})");
    let mut conf = cfg();
    conf.classifier.d_strong_c = 1e6;
    let p = c.prep_cfg(&conf);
    let r = classify(&p, Variant::Heat);
    assert!(
        frozen_fraction(&r.freeze) > 0.99,
        "d_strong_c из конфига → заморозка"
    );
    conf.classifier.d_strong_axis = DStrongAxis::Fr;
    conf.classifier.d_strong_c = 1000.0;
    conf.classifier.d_fr_c = 1000.0;
    let p = c.prep_cfg(&conf);
    let r = classify(&p, Variant::Heat);
    assert!(
        frozen_fraction(&r.freeze) > 0.99,
        "d_strong_axis/d_strong_c из конфига → заморозка"
    );
    let mut conf = cfg();
    conf.classifier.omega_band = 0.7;
    let p = case("t_ax_u1.5").prep_cfg(&conf);
    assert!(
        (p.omega - 0.7).abs() < 0.05,
        "omega_band из конфига ({})",
        p.omega
    );
}

#[test]
fn convection_freezes_heat_variant_only() {
    // летний полдень (H 250 Вт/м², z_i 1500 м, ветер 1,2 м/с): F ведущая, свободная конвекция
    // (w* ≥ U_sat) отдана механизму; без нагрева F нет; w* в годовой статистике Allen 2006
    let c = case("t_fconv");
    let p = c.prep();
    let m = classify_pair(&p);
    let wmax = p.cols.wst.iter().cloned().fold(0.0, f64::max);
    let frac = phase_fractions(&m.heat.weights, p.n2);
    assert!((0.46..=5.02).contains(&wmax), "w* {wmax:.2} в [0,46; 5,02]");
    assert!(
        (p.zi_agl - 1500.0).abs() < 1.0,
        "z_i над низом рельефа — из случая"
    );
    assert!(
        frac[4] > 0.5,
        "F ведущая при сильном нагреве и слабом ветре ({:.2})",
        frac[4]
    );
    assert!(
        frozen_fraction(&m.heat.freeze) > 0.5,
        "свободная конвекция отдана механизму"
    );
    assert!(frozen_fraction(&m.mech.freeze) < 0.01, "без нагрева F нет");
    assert!(phase_fractions(&m.mech.weights, p.n2)[4] == 0.0);
}

#[test]
fn drainage_weight_enters_heat_variant() {
    // вечер в долине: G включён, вес G есть при штиле
    let c = case("t_gvalley");
    let p = c.prep();
    assert!(p.prm.gact, "G включён вечером");
    let m = classify_pair(&p);
    let g = phase_fractions(&m.heat.weights, p.n2)[5];
    assert!(g > 0.1, "вес G есть при штиле ({g:.2})");
    assert!(
        phase_fractions(&m.mech.weights, p.n2)[5] == 0.0,
        "без нагрева G нет"
    );
    // вечерние фикстуры: G включён, заморозка по G там, где вес ≥ freeze_w
    for tag in ["synthetic_eve_u6.0", "ongudai_eve_u6.0"] {
        let p = case(tag).prep();
        assert!(p.prm.gact);
        let r = classify(&p, Variant::Heat);
        for c in 0..p.n2 {
            if r.weights[5 * p.n2 + c] >= 0.5 {
                assert_eq!(r.freeze[c], 1, "{tag}: G ≥ freeze_w → колонна заморожена");
            }
        }
    }
}

#[test]
fn h_phase_has_no_forced_freeze_in_strong_wind() {
    for tag in ["synthetic_noon_u12.0", "ongudai_noon_u12.0", "t_contract"] {
        let p = case(tag).prep();
        let r = classify(&p, Variant::Mech);
        assert_eq!(frozen_fraction(&r.freeze), 0.0, "{tag}");
    }
}

#[test]
fn bad_input_is_error_not_panic() {
    let c = case("t_contract");
    let mut inp = c.input();
    inp.hc = &c.hc[1..];
    assert!(prepare(&inp, &cfg()).is_err());
    let mut inp = c.input();
    inp.nx = 2;
    assert!(prepare(&inp, &cfg()).is_err());
    let mut inp = c.input();
    inp.gam = &c.gam[1..];
    assert!(prepare(&inp, &cfg()).is_err());
}

// ---------------------------------------------------------------- (3) детерминизм

fn run_all(threads: usize) -> Vec<PhaseMaps> {
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(threads)
        .build()
        .unwrap();
    pool.install(|| cases().iter().map(|c| classify_pair(&c.prep())).collect())
}

#[test]
fn deterministic_1_and_4_threads_bitwise() {
    let a = run_all(1);
    let b = run_all(4);
    assert_eq!(a.len(), b.len());
    let bits = |v: &[f64]| v.iter().map(|f| f.to_bits()).collect::<Vec<_>>();
    for (i, (x, y)) in a.iter().zip(&b).enumerate() {
        let t = &cases()[i].tag;
        assert_eq!(
            bits(&x.heat.weights),
            bits(&y.heat.weights),
            "{t}: веса heat"
        );
        assert_eq!(x.heat.freeze, y.heat.freeze, "{t}: маска heat");
        assert_eq!(
            bits(&x.mech.weights),
            bits(&y.mech.weights),
            "{t}: веса mech"
        );
        assert_eq!(x.mech.freeze, y.mech.freeze, "{t}: маска mech");
    }
}
