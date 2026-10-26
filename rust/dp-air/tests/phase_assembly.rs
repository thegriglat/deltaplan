//! RW-6m: фазы 3 — F (баланс θ′, подобие слоя перемешивания), G (сток Прандтля + D8), сборка
//! тёплого старта `warm`/`warm_mech` и полей заморозки, маска запасного пути, статистика — против
//! GDScript `AirPhase.{drainage, stats}` и `AirPhaseCpu.{uml, theta, run_prepared}`.
//! Дамп — `tools/research/rust_wind/dump_phase_assembly.sh` (rust/dp-air/tests/data/phase_assembly):
//! плоскости стока и числа, `uml`/θ′, состояния (каждое 7-е значение; `t_gvalley` целиком),
//! статистика, маска запасного пути. Входы фаз — из дампа RW-6k (tests/data/phase) по тому же тегу.
//!
//! Проверки: (1) против дампа — поэлементно ≤ 1e-6 относительная (пол 1e-9 для значений, равных нулю
//! с точностью до округления), маски побитно; (2) числа `test_air_phase.gd` как утверждения (σ_w/w*,
//! `a_up`, w* Allen, Прандтль `l`, `Δθ`, сток по склону, холодное озеро) и штиль (U10 0,3) — область
//! заморожена целиком (`limits.md:86`); (3) детерминизм: 1 и 4 потока — побитно.
use dp_air::field::phase::assembly::{PhaseResult, assemble, assemble_prepared};
use dp_air::field::phase::classifier::{Variant, classify};
use dp_air::field::phase::config::PhaseCfg;
use dp_air::field::phase::convection::{convection_profile, theta, uml, updraft};
use dp_air::field::phase::drainage::{apply, drainage, prandtl};
use dp_air::field::phase::mech::MechFields;
use dp_air::field::phase::prepare::{
    GRAV, K, PH_F, PH_G, PHASES, PhaseCase, Prepared, RHO_CP, THETA0, prepare,
};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::OnceLock;

const REL: f64 = 1e-6;
const FLOOR: f64 = 1e-9;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn atmosphere() -> Value {
    let t = std::fs::read_to_string(root().join("../../configs/atmosphere.json")).unwrap();
    serde_json::from_str(&t).unwrap()
}

fn cfg() -> PhaseCfg {
    let t = std::fs::read_to_string(root().join("../../configs/atmosphere.json")).unwrap();
    PhaseCfg::from_json(&t).unwrap()
}

/// Допуск проверки из `air_phase.checks.<ключ>`.
fn chk(key: &str) -> Value {
    atmosphere()["air_phase"]["checks"][key].clone()
}

fn chk_f(key: &str) -> f64 {
    chk(key).as_f64().unwrap()
}

fn chk_range(key: &str) -> (f64, f64) {
    let v = chk(key);
    (v[0].as_f64().unwrap(), v[1].as_f64().unwrap())
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
    fn range(&self, k: &str, w: usize) -> &[u8] {
        let a = self.meta["arrays"]
            .get(k)
            .unwrap_or_else(|| panic!("нет массива {k}"));
        let (o, n) = (
            a["offset"].as_u64().unwrap() as usize,
            a["count"].as_u64().unwrap() as usize,
        );
        &self.bin[o..o + w * n]
    }
    fn f64s(&self, k: &str) -> Vec<f64> {
        self.range(k, 8)
            .chunks_exact(8)
            .map(|c| f64::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn f32s(&self, k: &str) -> Vec<f32> {
        self.range(k, 4)
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn u8s(&self, k: &str) -> Vec<u8> {
        self.range(k, 1).to_vec()
    }
    fn has(&self, k: &str) -> bool {
        self.meta["arrays"].get(k).is_some()
    }
}

/// Случай: вход фаз (дамп RW-6k) без стока (G считается здесь) и ожидания RW-6k.
struct Case {
    tag: String,
    scal: HashMap<String, f64>,
    hc: Vec<f64>,
    gam: Vec<f64>,
    heat: Vec<f64>,
    heat_used: Vec<f64>,
    h_bl: Vec<f64>,
    wst: Vec<f64>,
    zic: Vec<f64>,
    gw: Vec<f64>,
    frz_h: Vec<u8>,
    frz_m: Vec<u8>,
    /// G включён в GDScript.
    g_on: bool,
}

impl Case {
    fn s(&self, k: &str) -> f64 {
        self.scal[k]
    }
    fn input(&self) -> PhaseCase<'_> {
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
            g: None,
        }
    }
    /// Подготовка без стока.
    fn prep(&self) -> Prepared {
        prepare(&self.input(), &cfg()).unwrap()
    }
    /// Подготовка со стоком G (как `assemble`).
    fn prep_g(&self) -> (Prepared, Option<dp_air::field::phase::drainage::Drainage>) {
        let mut p = self.prep();
        let g = drainage(&p, &self.heat);
        if let Some(g) = &g {
            apply(&mut p, g);
        }
        (p, g)
    }
}

struct All {
    asm: Dump,
    cases: Vec<Case>,
}

fn all() -> &'static All {
    static A: OnceLock<All> = OnceLock::new();
    A.get_or_init(|| {
        let ph = Dump::load("tests/data/phase", "phase");
        let asm = Dump::load("tests/data/phase_assembly", "phase_assembly");
        let fields: Vec<String> = ph.meta["scal_fields"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        let cases = asm.meta["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| {
                let tag = c["tag"].as_str().unwrap().to_string();
                let sv = ph.f64s(&format!("{tag}/scal"));
                Case {
                    scal: fields.iter().cloned().zip(sv).collect(),
                    hc: ph.f64s(&format!("{tag}/hc")),
                    gam: ph.f64s(&format!("{tag}/gam")),
                    heat: ph.f64s(&format!("{tag}/heat")),
                    heat_used: ph.f64s(&format!("{tag}/heat_used")),
                    h_bl: ph.f64s(&format!("{tag}/h_bl")),
                    wst: ph.f64s(&format!("{tag}/wst")),
                    zic: ph.f64s(&format!("{tag}/zic")),
                    gw: ph.f64s(&format!("{tag}/gw")),
                    frz_h: ph.u8s(&format!("{tag}/frz_h")),
                    frz_m: ph.u8s(&format!("{tag}/frz_m")),
                    g_on: c["g"].as_bool().unwrap(),
                    tag,
                }
            })
            .collect();
        All { asm, cases }
    })
}

fn case(tag: &str) -> &'static Case {
    all()
        .cases
        .iter()
        .find(|c| c.tag == tag)
        .unwrap_or_else(|| panic!("нет случая {tag}"))
}

/// Наибольшая поэлементная относительная ошибка `|a − b| / (|b| + FLOOR/REL)` и номер элемента.
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

fn to64(a: &[f32]) -> Vec<f64> {
    a.iter().map(|&x| f64::from(x)).collect()
}

fn stride_of(d: &Dump) -> usize {
    d.meta["stride"].as_u64().unwrap() as usize
}

/// Выборка состояния как в дампе: целиком или каждое `stride`-е значение.
fn sampled(d: &Dump, tag: &str, a: &[f32]) -> Vec<f64> {
    let full = d.meta["arrays"][format!("{tag}/warm_h_u")]["count"]
        .as_u64()
        .unwrap() as usize
        == a.len();
    if full {
        to64(a)
    } else {
        a.iter()
            .step_by(stride_of(d))
            .map(|&x| f64::from(x))
            .collect()
    }
}

// ---------------------------------------------------------------- (1) против дампа

#[test]
fn drainage_planes_match_dump() {
    let a = all();
    let (mut worst, mut n_g) = (0.0f64, 0);
    for c in &a.cases {
        let p = c.prep();
        let g = drainage(&p, &c.heat);
        assert_eq!(g.is_some(), c.g_on, "{}: G включён", c.tag);
        let Some(g) = g else { continue };
        n_g += 1;
        // вес G совпадает с входом RW-6k (тот же GDScript-прогон)
        worst = worst.max(expect_close(
            &format!("{}: вес G (RW-6k)", c.tag),
            &g.gw,
            &c.gw,
        ));
        let want = a.asm.f64s(&format!("{}/g", c.tag));
        let n2 = p.n2;
        let planes: [(&str, &[f64]); 10] = [
            ("GL", &g.gl),
            ("GDTH", &g.gdth),
            ("GUS", &g.gus),
            ("GON", &g.gon),
            ("GLAY", &g.glay),
            ("GD", &g.gd),
            ("GUC", &g.guc),
            ("GDX", &g.gdx),
            ("GDY", &g.gdy),
            ("GW", &g.gw),
        ];
        for (q, (name, pl)) in planes.iter().enumerate() {
            worst = worst.max(expect_close(
                &format!("{}: плоскость {name}", c.tag),
                pl,
                &want[q * n2..(q + 1) * n2],
            ));
        }
        let d = &g.diag;
        let got = [
            d.dth_c,
            d.heat_mean,
            d.umax_med,
            d.l_med,
            d.layer_frac,
            d.d_layer_med,
            d.uc_layer_med,
            d.w_mean,
            d.w_ge_frac,
        ];
        worst = worst.max(expect_close(
            &format!("{}: числа стока", c.tag),
            &got,
            &a.asm.f64s(&format!("{}/gdiag", c.tag)),
        ));
        assert!(
            (d.dth_c - c.s("g_dth_c")).abs() <= REL * d.dth_c.abs() + FLOOR,
            "{}: Δθ_c против RW-6k",
            c.tag
        );
    }
    assert!(n_g >= 8, "случаев со стоком: {n_g}");
    println!("phase_assembly: сток G, {n_g} случаев, наибольшая ошибка {worst:e}");
}

#[test]
fn convection_balance_matches_dump() {
    let a = all();
    let (mut worst, mut n_h) = (0.0f64, 0);
    for c in &a.cases {
        let (p, _) = c.prep_g();
        if !p.heated {
            assert!(!a.asm.has(&format!("{}/theta", c.tag)));
            continue;
        }
        n_h += 1;
        let mf = MechFields::new(&p);
        let w = classify(&p, Variant::Heat);
        let um = uml(&p, &w, &mf);
        let th = theta(&p, &um);
        worst = worst.max(expect_close(
            &format!("{}: скорость слоя перемешивания", c.tag),
            &um,
            &a.asm.f64s(&format!("{}/uml", c.tag)),
        ));
        worst = worst.max(expect_close(
            &format!("{}: θ′ слоя перемешивания", c.tag),
            &th,
            &a.asm.f64s(&format!("{}/theta", c.tag)),
        ));
    }
    assert!(n_h >= 12, "случаев с нагревом: {n_h}");
    println!("phase_assembly: uml, θ′ слоя, {n_h} случаев, наибольшая ошибка {worst:e}");
}

fn check_state(what: &str, d: &Dump, tag: &str, var: &str, s: &picard_rs::state::State) -> f64 {
    let mut worst = 0.0f64;
    for (nm, arr) in [("u", &s.u), ("v", &s.v), ("w", &s.w), ("th", &s.th)] {
        let key = format!("{tag}/warm_{var}_{nm}");
        let want = to64(&d.f32s(&key));
        worst = worst.max(expect_close(
            &format!("{what}: {key}"),
            &sampled(d, tag, arr),
            &want,
        ));
    }
    worst
}

#[test]
fn assembly_matches_dump() {
    let a = all();
    let mut worst = 0.0f64;
    let (mut ng, mut nf) = (0, 0);
    for c in &a.cases {
        let (p, g) = c.prep_g();
        let r = assemble_prepared(&p, g.as_ref());
        assert!(!r.nan_found, "{}: нечисловые значения в сборке", c.tag);
        let d = &p;
        let dims = r.warm.dims;
        assert_eq!(dims[0] * dims[1] * dims[2], d.big_n);
        worst = worst.max(check_state(&c.tag, &a.asm, &c.tag, "h", &r.warm));
        worst = worst.max(check_state(&c.tag, &a.asm, &c.tag, "m", &r.warm_mech));
        // маски заморозки — побитно (RW-6k); запасной путь — побитно
        assert_eq!(r.maps.heat.freeze, c.frz_h, "{}: маска (нагрев)", c.tag);
        assert_eq!(
            r.maps.mech.freeze, c.frz_m,
            "{}: маска (без нагрева)",
            c.tag
        );
        assert_eq!(r.freeze.mask, c.frz_h);
        assert_eq!(r.freeze_mech.mask, c.frz_m);
        let want_nc = a.asm.u8s(&format!("{}/nonconv", c.tag));
        match &r.nonconv {
            Some(nc) => assert_eq!(nc.mask, want_nc, "{}: колонны запасного пути", c.tag),
            None => assert!(want_nc.is_empty(), "{}: запасной путь пуст", c.tag),
        }
        ng += usize::from(g.is_some());
        nf += usize::from(r.nonconv.is_some());
        // поле заморозки — состояние варианта; поле запасного пути — warm со слоем mech_field
        let ff = r.freeze.field.as_ref().unwrap();
        assert!(ff.u == r.warm.u && ff.v == r.warm.v && ff.w == r.warm.w && ff.th == r.warm.th);
        let fm = r.freeze_mech.field.as_ref().unwrap();
        assert!(fm.u == r.warm_mech.u && fm.th == r.warm_mech.th);
        if let Some(nc) = &r.nonconv {
            let f = nc.field.as_ref().unwrap();
            assert!(f.u == r.warm.u && f.w == r.warm.w && f.th == r.warm.th);
        }
        // раскладка W11: ореол, размеры
        assert_eq!(r.warm.halo, 1);
        assert_eq!(r.warm.n, [p.nx, p.ny, dims[2] - 2]);
        assert_eq!(r.warm.u.len(), d.big_n);
        assert_eq!(r.freeze.mask.len(), p.n2);
        // над землёй поле есть, под землёй и в k = 0 — нули
        let nyx = dims[0] * dims[1];
        assert!(
            r.warm.u[..nyx].iter().all(|&x| x == 0.0),
            "{}: k = 0",
            c.tag
        );
        assert!(r.warm.w[..nyx].iter().all(|&x| x == 0.0));
    }
    assert!(ng >= 8 && nf >= 1, "стоков {ng}, запасных путей {nf}");
    println!("phase_assembly: состояния, наибольшая ошибка {worst:e}; G {ng}, запасной путь {nf}");
}

#[test]
fn stats_match_dump() {
    let a = all();
    let fields: Vec<String> = a.asm.meta["stat_fields"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    let gfields = a.asm.meta["g_fields"].as_array().unwrap().len();
    let mut worst = 0.0f64;
    for c in &a.cases {
        let r = assemble(&c.input(), &cfg()).unwrap();
        let s = &r.stats;
        let pick = |nm: &str| -> f64 {
            match nm {
                "fr" => s.fr,
                "n_bv" => s.n_bv,
                "u_over_n" => s.u_over_n,
                "w_h_case" => s.w_h_case,
                "w_d_strong" => s.w_d_strong,
                "w_d_case" => s.w_d_case,
                "full_mech" => f64::from(u8::from(s.full_mech)),
                "u_sat" => s.u_sat,
                "u10" => s.u10,
                "omega" => s.omega,
                "b_fr" => s.b_fr,
                "b_u" => s.b_u,
                "frozen_frac" => s.frozen_frac,
                "frozen_frac_mech" => s.frozen_frac_mech,
                "hc_dividing" => s.hc_dividing,
                "d_layers" => s.d_layers as f64,
                "shadow_frac" => s.shadow_frac,
                "h_spread" => s.h_spread,
                "wstar_max" => s.wstar_max,
                "wstar_f" => s.wstar_f,
                "zi_agl" => s.zi_agl,
                _ => panic!("поле статистики {nm}"),
            }
        };
        let mut got: Vec<f64> = fields.iter().map(|f| pick(f)).collect();
        got.extend_from_slice(&s.phase_frac);
        worst = worst.max(expect_close(
            &format!("{}: статистика", c.tag),
            &got,
            &a.asm.f64s(&format!("{}/stats", c.tag)),
        ));
        assert_eq!(s.g.is_some(), c.g_on);
        assert_eq!(gfields, 9);
        assert!(
            r.omega
                .iter()
                .all(|&o| f64::from(o) == f64::from(s.omega as f32))
        );
    }
    // подобие слоя перемешивания
    let want = a.asm.f64s("convection");
    let got: Vec<f64> = convection_profile(&cfg())
        .iter()
        .flat_map(|(zr, u)| [*zr, u.sigma_w, u.w3, u.skew, u.a_up, u.w_up])
        .collect();
    worst = worst.max(expect_close("подобие слоя перемешивания", &got, &want));
    println!("phase_assembly: статистика, наибольшая ошибка {worst:e}");
}

// ---------------------------------------------------------------- (2) числа test_air_phase.gd

#[test]
fn f_similarity_numbers() {
    let c = cfg();
    // доля восходящих 0,3–0,5 [LS80] на 0,2–0,8 z_i
    let (lo, hi) = chk_range("f_updraft_frac");
    for q in 2..9 {
        let u = updraft(&c, f64::from(q) / 10.0);
        assert!(u.a_up >= lo && u.a_up <= hi, "a_up({q}/10) = {:.3}", u.a_up);
    }
    // σ_w/w*: максимум ≈ 0,6 на 0,2–0,45 z_i [LWP80]
    let (mut peak, mut zpk) = (0.0f64, 0.0f64);
    for q in 1..100 {
        let u = updraft(&c, f64::from(q) / 100.0);
        if u.sigma_w > peak {
            peak = u.sigma_w;
            zpk = f64::from(q) / 100.0;
        }
    }
    assert!((peak / chk_f("f_sigw_peak") - 1.0).abs() <= chk_f("f_sigw_peak_tol"));
    let (zlo, zhi) = chk_range("f_sigw_peak_z");
    assert!(zpk >= zlo && zpk <= zhi, "максимум σ_w на {zpk}");
    // средний подъём в термике ŵ ≥ 0,45 w* на 0,25 z_i [LS80]
    assert!(updraft(&c, 0.25).w_up >= chk_f("f_wmean_peak"));
    println!(
        "phase_assembly F: σ_w max {peak:.3} w* на {zpk:.2} z_i; a_up(0,25) {:.3}",
        updraft(&c, 0.25).a_up
    );
}

#[test]
fn f_convective_noon() {
    // летний полдень (H 250, z_i 1500 м, ветер 1,2 м/с, N 0,003): w* в статистике Allen 2006,
    // F ведущая, колонны свободной конвекции (w* ≥ U_sat) отданы механизму
    let c = case("t_fconv");
    let r = assemble(&c.input(), &cfg()).unwrap();
    let s = &r.stats;
    let (lo, hi) = chk_range("f_wstar_range");
    assert!(
        s.wstar_max >= lo && s.wstar_max <= hi,
        "w* {:.2}",
        s.wstar_max
    );
    assert!((s.zi_agl - 1500.0).abs() < 1.0, "z_i над низом рельефа");
    assert!(
        s.phase_frac[PH_F] > 0.5,
        "F ведущая: {:.2}",
        s.phase_frac[PH_F]
    );
    assert!(s.frozen_frac > 0.5, "свободная конвекция отдана механизму");
    assert!(s.frozen_frac_mech < 0.01, "без нагрева F нет");
    // θ′ в слое перемешивания > 0 над центром области (баланс тепла столба)
    let d = r.warm.dims;
    let col = (r.warm.n[1] / 2 + 1) * d[0] + r.warm.n[0] / 2 + 1;
    assert!(
        r.warm.th[3 * d[0] * d[1] + col] > 0.0,
        "θ′ в слое перемешивания"
    );
}

#[test]
fn g_prandtl_numbers() {
    let g = cfg().g;
    let tol = chk_f("g_prandtl_tol");
    // профиль Прандтля: максимум u на n = πl/4, u_max = e^(−π/4) sin(π/4)·u_s, Δθ = |H| l/(ρc_p K)
    let pr = prandtl(&g, 0.1, 0.01, -30.0);
    let (mut best, mut nbest) = (0.0f64, 0.0f64);
    for q in 0..4000 {
        let nn = f64::from(q) * pr.l / 1000.0;
        let u = pr.us * (-nn / pr.l).exp() * (nn / pr.l).sin();
        if u > best {
            best = u;
            nbest = nn;
        }
    }
    assert!(
        (nbest / pr.nj - 1.0).abs() < 2.0 * tol + 4.0 / 1000.0,
        "максимум на πl/4"
    );
    assert!((best / pr.umax - 1.0).abs() < tol, "u_max = 0,322·u_s");
    let dth_closure = 30.0 * pr.l / (RHO_CP * g.k_m2s);
    assert!(
        (pr.dth / dth_closure - 1.0).abs() < tol,
        "Δθ по замыканию потоком"
    );
    assert!(
        (pr.umax
            / (pr.us * (-std::f64::consts::FRAC_PI_4).exp() * std::f64::consts::FRAC_PI_4.sin())
            - 1.0)
            .abs()
            < 1e-12
    );
    assert!(
        (pr.dth * GRAV / (THETA0 * 0.01) - pr.us).abs() <= 1e-12,
        "u_s = Δθ g/(θ0 N)"
    );
    println!(
        "phase_assembly G: l {:.1} м, Δθ {:.2} К, u_max {:.2} м/с на {:.1} м",
        pr.l, pr.dth, pr.umax, pr.nj
    );
    // скорость стока на типичных склонах [ZW13: 1–4 м/с]
    let (lo, hi) = chk_range("g_speed_range");
    for (s, n, h) in [
        (0.1, 0.01, -30.0),
        (0.2, 0.01, -40.0),
        (0.15, 0.012, -40.0),
        (0.05, 0.01, -20.0),
    ] {
        let p2 = prandtl(&g, s, n, h);
        assert!(
            p2.umax >= lo && p2.umax <= hi,
            "u_max {:.2} (sin α {s})",
            p2.umax
        );
    }
}

#[test]
fn g_valley_evening() {
    // вечер в долине: выхолаживание −40 Вт/м², штиль; G включён, сток вниз по склону у земли,
    // холодное озеро на дне
    let c = case("t_gvalley");
    let r = assemble(&c.input(), &cfg()).unwrap();
    let g = r.stats.g.expect("G включён вечером");
    let (lo, hi) = chk_range("g_speed_range");
    assert!(
        g.umax_med >= lo && g.umax_med <= hi,
        "медиана u_max {:.2}",
        g.umax_med
    );
    assert!(
        r.stats.phase_frac[PH_G] > 0.1,
        "вес G при штиле: {:.2}",
        r.stats.phase_frac[PH_G]
    );
    let (n, dz, zb) = (24usize, c.s("dz"), c.s("z_bot"));
    let d = r.warm.dims;
    let at = |a: &[f32], k: usize, j: usize, i: usize| a[(k * d[1] + j + 1) * d[0] + i + 1];
    // восточный склон долины (к центру — на запад): u < 0 у земли
    let (i, j) = (n * 3 / 4, n / 2);
    let k = ((c.hc[j * n + i] - zb) / dz + 0.5).ceil() as usize;
    let uc = 0.5 * (at(&r.warm.u, k, j, i) + at(&r.warm.u, k, j, i + 1));
    assert!(uc < 0.0, "сток вниз по склону (u = {uc:.2} м/с)");
    // дно долины — гидравлический слой: θ′ = −Δθ(1 − z/d) < 0 у земли
    let ic = n / 2;
    let kc = ((c.hc[ic * n + ic] - zb) / dz + 0.5).ceil() as usize;
    let thc = at(&r.warm.th, kc, ic, ic);
    assert!(thc < 0.0, "холодное озеро на дне долины (θ′ = {thc:.2} К)");
}

#[test]
fn calm_freezes_whole_region() {
    // штиль U10 0,3 м/с: область заморожена целиком, оба решения (limits.md:86); у сильного
    // ветра 12 м/с у холма не вся
    for c in &all().cases {
        if c.s("u10") != 0.3 {
            continue;
        }
        let r = assemble(&c.input(), &cfg()).unwrap();
        assert!(r.stats.full_mech, "{}: вся область — механизм", c.tag);
        assert!(
            r.stats.frozen_frac_mech > 1.0 - 1e-9,
            "{}: mech заморожен целиком",
            c.tag
        );
        assert!(r.freeze_mech.mask.iter().all(|&b| b == 1), "{}", c.tag);
        assert!(
            r.freeze.mask.iter().all(|&b| b == 1),
            "{}: нагрев тоже",
            c.tag
        );
    }
    let r = assemble(&case("t_ax_u12").input(), &cfg()).unwrap();
    assert!(r.stats.frozen_frac < 1.0 && !r.stats.full_mech);
}

#[test]
fn weights_sum_to_one_and_stats_consistent() {
    for c in &all().cases {
        let r = assemble(&c.input(), &cfg()).unwrap();
        let n2 = r.omega.len();
        for m in [&r.maps.heat, &r.maps.mech] {
            for q in 0..n2 {
                let s: f64 = (0..K).map(|k| m.weights[k * n2 + q]).sum();
                assert!((s - 1.0).abs() < 1e-9, "{}: Σw = {s}", c.tag);
            }
        }
        let tot: f64 = r.stats.phase_frac.iter().sum();
        assert!(
            (tot - 1.0).abs() < 1e-5,
            "{}: Σ долей {tot} ({PHASES:?})",
            c.tag
        );
    }
}

/// Полоса `nx × ny` с ветром вдоль +x: слой `h` и кинематический поток `hk` по столбцам; θ′ механизма F.
fn theta_strip(
    base: &Prepared,
    i_sea: usize,
    sea: (f64, f64),
    land: (f64, f64),
    sea_first: bool,
) -> Vec<f64> {
    let mut p = base.clone();
    p.prm.dx = 400.0;
    p.prm.ex = 1.0;
    p.prm.ey = 0.0;
    p.prm.tau = 3600.0;
    for c in 0..p.n2 {
        let is_sea = ((c % p.nx) < i_sea) == sea_first;
        let (h, hk) = if is_sea { sea } else { land };
        p.cols.hbl[c] = h;
        p.cols.hk[c] = hk;
    }
    theta(&p, &vec![4.0; p.n2])
}

#[test]
fn f_heat_content_is_transported() {
    // TW-3: F переносит теплосодержание θ′·h. Тонкий холодный слой над морем (h 50 м) почти не
    // меняет θ′ толстого слоя суши (1500 м); обратно (суша → море) θ′ не раздувается; однородно —
    // θ′ = H_k/h·τ·(1 − e^{−(i+1)Δt/τ})
    let base = case("t_contract").prep();
    let nx = base.nx;
    let i0 = 8;
    let cold = theta_strip(&base, i0, (50.0, -0.05), (1500.0, 0.15), true);
    let calm = theta_strip(&base, i0, (50.0, 0.0), (1500.0, 0.15), true);
    let (c_sea, c_land) = (nx + i0 - 1, nx + i0);
    let th_sea = cold[c_sea];
    let d = (cold[c_land] - calm[c_land]).abs();
    let fa = (-400.0f64 / 4.0 / 3600.0).exp();
    assert!(
        th_sea < -0.5,
        "море выхолаживает тонкий слой ({th_sea:.2} К)"
    );
    assert!(
        d <= th_sea.abs() * 50.0 / 1500.0 * fa * 1.001,
        "Δθ′ суши = θ′_моря·h_моря/h_суши ({d:.4})"
    );
    assert!(d < 0.05 * th_sea.abs(), "суша почти не выхоложена");
    let back = theta_strip(&base, i0, (50.0, 0.0), (1500.0, 0.15), false);
    assert!(
        back[c_land] <= back[c_sea] * 1.0001 && back[c_land] > 0.0,
        "суша → море: θ′ не раздувается"
    );
    let flat = theta_strip(&base, 0, (50.0, 0.0), (1500.0, 0.15), true);
    let want = 0.15 / 1500.0 * 3600.0 * (1.0 - fa.powi(11));
    assert!(
        (flat[nx + 10] - want).abs() <= 1e-6 * want,
        "однородно: {} = {want}",
        flat[nx + 10]
    );
}

// ---------------------------------------------------------------- (3) детерминизм

fn bits(r: &PhaseResult) -> Vec<u32> {
    let mut o = Vec::new();
    for s in [&r.warm, &r.warm_mech] {
        for a in [&s.u, &s.v, &s.w, &s.th] {
            o.extend(a.iter().map(|x| x.to_bits()));
        }
    }
    o.extend(
        r.maps
            .heat
            .weights
            .iter()
            .map(|x| (x.to_bits() >> 11) as u32),
    );
    o.extend(r.maps.heat.freeze.iter().map(|&b| u32::from(b)));
    o.extend(
        r.nonconv
            .iter()
            .flat_map(|n| n.mask.iter().map(|&b| u32::from(b))),
    );
    o
}

#[test]
fn deterministic_1_and_4_threads() {
    let run = |threads: usize| {
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .unwrap();
        pool.install(|| {
            let mut out = Vec::new();
            for tag in ["t_gvalley", "t_fconv", "t_contract", "synthetic_eve_u1.5"] {
                out.extend(bits(&assemble(&case(tag).input(), &cfg()).unwrap()));
            }
            out
        })
    };
    assert!(run(1) == run(4), "1 и 4 потока — побитно");
}
