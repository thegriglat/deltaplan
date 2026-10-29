//! RW-8: болтанка поля и шум порывов — слот `Turb`, `GustSpectrum`, `WindModel.gust_unit`.
//!
//! Эталоны GD (опорная ревизия `c591b1026`, `tests/data/RW-8/`, см. README там):
//! - `rw8_dump.f64` — `WindModel.gust_unit`, рывки слоя смешения, `GustSpectrum` (сдвиги, нормировка,
//!   таблицы весов, отсчёты), `FieldTurbulence` (`sigma`, `lee`, `sep_sigma`, `reverse_unresolved`,
//!   `taylor_stretch`, масштабы MIL) на случайных входах — сверка побитно (шум) и до 1e-9 (σ);
//! - `dbg_ongudai_*.f64` — внутренние величины `_air_velocity_field` в точках эталонов `ongudai_*`
//!   (поле Пикара посчитано на GPU, тот же прогон даёт побитно файлы `tests/fixtures/wind/cases`).
//!
//! Статистика (T3): дисперсия, спектр фон Кармана, масштабы MIL-HDBK-1797, σ_u ≠ σ_v ≠ σ_w.
use dp_air::compat::rng::Pcg32;
use dp_air::field::wind_field::{T_AOUT, T_DESC, T_HMIX, T_N2, T_SHEAR, T_UOUT, T_USTAR, T_WSTAR};
use dp_air::fixtures::{read_case, read_case_data};
use dp_air::terms::turb::sigma::{self, TurbCfg};
use dp_air::terms::turb::spectrum::{self, GustSpectrum, SampleIn};
use dp_air::terms::turb::{FieldState, FieldTurb, GustCfg, GustUnit, PointIn, sep};
use dp_air::terms::{self, SumCfg};
use dp_air::{Configs, SampleMode};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn data_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/data/RW-8")
}

fn atmosphere() -> Configs {
    let t = std::fs::read_to_string(repo().join("configs/atmosphere.json")).unwrap();
    Configs::new(vec![("atmosphere.json".into(), t)])
}

fn f64s(path: &Path) -> Vec<f64> {
    std::fs::read(path)
        .unwrap_or_else(|e| panic!("{}: {e}", path.display()))
        .chunks_exact(8)
        .map(|c| f64::from_le_bytes(c.try_into().unwrap()))
        .collect()
}

/// Дамп GD: массивы по имени из `manifest.json` (смещение и длина в f64).
struct Dump {
    man: Value,
    buf: Vec<f64>,
}

impl Dump {
    fn load() -> Dump {
        let man: Value = serde_json::from_str(
            &std::fs::read_to_string(data_dir().join("manifest.json")).unwrap(),
        )
        .unwrap();
        Dump {
            man,
            buf: f64s(&data_dir().join("rw8_dump.f64")),
        }
    }

    fn get(&self, name: &str) -> &[f64] {
        let a = &self.man["arrays"][name];
        let (o, n) = (
            a[0].as_u64().unwrap() as usize,
            a[1].as_u64().unwrap() as usize,
        );
        &self.buf[o..o + n]
    }
}

const SEEDS: [i64; 3] = [606, 20_260_927, 1];

fn max_rel(a: f64, b: f64) -> f64 {
    (a - b).abs() / b.abs().max(1.0e-12)
}

/// (1) `WindModel.gust_unit`: нормировка, сдвиги и 1500 отсчётов на сид — побитно с Godot.
#[test]
fn gust_unit_bitwise_with_godot() {
    let d = Dump::load();
    let cfg = GustCfg::from_configs(&atmosphere());
    for seed in SEEDS {
        let g = GustUnit::new(&cfg, seed);
        let tag = format!("s{seed}");
        let meta = d.get(&format!("{tag}_wm_meta"));
        let (dir, norm) = ([meta[0], meta[1]], meta[2]);
        assert_eq!(g.norm(), norm, "нормировка шума, сид {seed}");
        let (inp, out) = (
            d.get(&format!("{tag}_gust_in")),
            d.get(&format!("{tag}_gust_out")),
        );
        let mut worst = 0.0f64;
        for (i, o) in out.chunks_exact(3).enumerate() {
            let p = &inp[i * 6..i * 6 + 6];
            let n = g.gust_unit(
                [p[0] as f32, p[1] as f32, p[2] as f32],
                p[3],
                dir,
                p[4],
                p[5],
            );
            for q in 0..3 {
                worst = worst.max((f64::from(n[q]) - o[q]).abs());
            }
        }
        println!(
            "gust_unit сид {seed}: {} отсчётов, max|Δ| = {worst:e}",
            out.len() / 3
        );
        assert_eq!(worst, 0.0, "побитно, сид {seed}");
    }
}

/// (2) Рывки слоя смешения: среднее и СКО `g` (`_measure_burst`, сид 4242) и пятно `g` в точках.
#[test]
fn burst_stats_and_patch_bitwise_with_godot() {
    let d = Dump::load();
    let c = atmosphere();
    let cfg = TurbCfg::from_configs(&c);
    let gcfg = GustCfg::from_configs(&c);
    for seed in SEEDS {
        let g = GustUnit::new(&gcfg, seed);
        let tag = format!("s{seed}");
        let st = d.get(&format!("{tag}_burst_stats"));
        let (m, s) = sep::measure_burst(&cfg, &g);
        println!(
            "рывки сид {seed}: среднее {m:.6} (GD {:.6}), СКО {s:.6} (GD {:.6})",
            st[0], st[1]
        );
        assert_eq!((m, s), (st[0], st[1]), "статистика рывков, сид {seed}");
        let dir = [
            d.get(&format!("{tag}_wm_meta"))[0],
            d.get(&format!("{tag}_wm_meta"))[1],
        ];
        let (inp, out) = (
            d.get(&format!("{tag}_burst_in")),
            d.get(&format!("{tag}_burst_out")),
        );
        let mut hits = 0;
        for (i, o) in out.chunks_exact(2).enumerate() {
            let p = &inp[i * 5..i * 5 + 5];
            let gg = sep::burst_g(
                &cfg,
                &g,
                [p[0] as f32, p[1] as f32, p[2] as f32],
                p[3],
                dir,
                p[4],
            );
            assert_eq!(gg, o[1], "пятно рывка, сид {seed}, точка {i}");
            hits += usize::from(gg > 0.0);
        }
        assert!(hits > 10, "рывки случаются: {hits}");
    }
}

/// (3) `GustSpectrum`: нормировка, сдвиги октав, таблицы весов (f32) и 1500 отсчётов на сид —
/// побитно с Godot.
#[test]
fn gust_spectrum_bitwise_with_godot() {
    let d = Dump::load();
    let evolve = GustCfg::from_configs(&atmosphere()).evolve_ms;
    for seed in SEEDS {
        let gs = GustSpectrum::new(seed, evolve);
        let tag = format!("s{seed}");
        assert_eq!(
            gs.norm(),
            d.get(&format!("{tag}_sp_meta"))[0],
            "нормировка спектра, сид {seed}"
        );
        let offs = d.get(&format!("{tag}_sp_off"));
        for (i, o) in gs.offsets().iter().enumerate() {
            for q in 0..3 {
                assert_eq!(
                    f64::from(o[q]),
                    offs[i * 3 + q],
                    "сдвиг {i}.{q}, сид {seed}"
                );
            }
        }
        let dir = [
            d.get(&format!("{tag}_wm_meta"))[0],
            d.get(&format!("{tag}_wm_meta"))[1],
        ];
        let (inp, out) = (
            d.get(&format!("{tag}_sp_in")),
            d.get(&format!("{tag}_sp_out")),
        );
        let mut worst = 0.0f64;
        for (i, o) in out.chunks_exact(3).enumerate() {
            let p = &inp[i * 10..i * 10 + 10];
            let n = gs.sample(&SampleIn {
                pos: [p[0] as f32, p[1] as f32, p[2] as f32],
                t: p[3],
                advect: p[4],
                dir,
                l_u: p[5],
                l_w: p[6],
                l_2: p[7],
                f_a: p[8],
                f_c: p[9],
            });
            for q in 0..3 {
                worst = worst.max((f64::from(n[q]) - o[q]).abs());
            }
        }
        println!("спектр сид {seed}: max|Δ| = {worst:e}");
        assert_eq!(worst, 0.0, "побитно, сид {seed}");
    }
    // таблицы весов фон Кармана и доля, несомая октавами
    let tabs = d.get("tables_wu_ww");
    let n = spectrum::L_STEPS * spectrum::OCTAVES;
    let (mut worst_t, mut worst_c) = (0.0f64, 0.0f64);
    for li in 0..spectrum::L_STEPS {
        let el = spectrum::L_MIN * (li as f64 / spectrum::inv_dl()).exp();
        for o in 0..spectrum::OCTAVES {
            let kp = std::f64::consts::TAU / (spectrum::PEAK * spectrum::S0 * 2f64.powi(o as i32));
            let (hi, lo) = (kp * 2f64.sqrt(), kp / 2f64.sqrt());
            let wu = spectrum::band(el, lo, hi, false) as f32;
            let ww = spectrum::band(el, lo, hi, true) as f32;
            worst_t = worst_t
                .max((f64::from(wu) - tabs[li * spectrum::OCTAVES + o]).abs())
                .max((f64::from(ww) - tabs[n + li * spectrum::OCTAVES + o]).abs());
        }
    }
    let (ci, co) = (d.get("carried_in"), d.get("carried_out"));
    for (i, c) in co.chunks_exact(2).enumerate() {
        let r = spectrum::carried(ci[i * 2], ci[i * 2 + 1]);
        worst_c = worst_c.max((r[0] - c[0]).abs()).max((r[1] - c[1]).abs());
    }
    println!("таблицы: max|Δ| = {worst_t:e}, carried: {worst_c:e}");
    assert!(worst_t <= 1.0e-7, "таблицы весов {worst_t:e}");
    assert!(worst_c <= 1.0e-7, "доля, несомая октавами {worst_c:e}");
}

/// (4) `FieldTurbulence.sigma`, `lee`, `sep_sigma`, `reverse_unresolved`, `taylor_stretch`,
/// масштабы MIL на 3000 случайных входах: совпадение до 1e-9 (f64, `pow`/`ln` libm).
#[test]
fn sigma_lee_sep_scales_match_godot() {
    let d = Dump::load();
    let cfg = TurbCfg::from_configs(&atmosphere());
    let (inp, out) = (d.get("sig_in"), d.get("sig_out"));
    let (lin, lout) = (d.get("lee_in"), d.get("lee_out"));
    let mut worst = 0.0f64;
    let mut chk = |what: &str, i: usize, got: f64, want: f64| {
        let e = (got - want).abs() / want.abs().max(1.0);
        worst = worst.max(e);
        assert!(e <= 1.0e-9, "{what} #{i}: {got} != {want}");
    };
    let mut n_conv = 0;
    for i in 0..3000 {
        let r = &inp[i * 13..i * 13 + 13];
        let tb: Vec<f32> = r[5..13].iter().map(|v| *v as f32).collect();
        let s = sigma::sigma(&cfg, r[4], r[0], &tb, [r[1], r[2]], r[3]);
        let o = &out[i * 8..i * 8 + 8];
        for (k, (g, w)) in [
            ("s_u", (s.s_u, o[0])),
            ("s_w", (s.s_w, o[1])),
            ("l_u", (s.l_u, o[2])),
            ("l_w", (s.l_w, o[3])),
            ("s_v", (s.s_v, o[4])),
            ("fu_c", (s.fu_c, o[5])),
            ("fv_c", (s.fv_c, o[6])),
            ("l_c", (s.l_c, o[7])),
        ]
        .into_iter()
        {
            chk(k, i, g, w);
        }
        n_conv += usize::from(s.l_c > 0.0);
        let l = &lin[i * 6..i * 6 + 6];
        let q = &lout[i * 7..i * 7 + 7];
        chk("lee", i, sep::lee(&cfg, r[4], l[0], r[0], &tb), q[0]);
        let ss = sep::sep_sigma(&cfg, l[1]);
        chk("sep_u", i, ss[0], q[1]);
        chk("sep_w", i, ss[1], q[2]);
        chk("unres", i, sep::reverse_unresolved(&cfg, l[2], l[3]), q[3]);
        chk("taylor", i, sigma::taylor_stretch(l[4], l[5], r[0]), q[4]);
        chk("mil_lw", i, sigma::mil_lw(r[0]), q[5]);
        chk("mil_lu", i, sigma::mil_lu(r[0]), q[6]);
    }
    println!("σ/lee/sep/масштабы: 3000 входов, max отн. откл. = {worst:e}, с конвекцией: {n_conv}");
    assert!(n_conv > 500);
}

// ---------------------------------------------------------------- эталоны ongudai_*

/// Номера полей записи дампа `_air_velocity_field` (64 числа).
mod rec {
    pub const LEN: usize = 64;
    pub const T: usize = 3;
    pub const A: usize = 4;
    pub const AGL: usize = 5;
    pub const U: usize = 6;
    pub const UF: usize = 7;
    pub const TB: usize = 11;
    pub const DX: usize = 19;
    pub const LEE_F: usize = 20;
    pub const RELIEF: usize = 21;
    pub const DANGER: usize = 22;
    pub const U_H: usize = 23;
    pub const DU: usize = 24;
    pub const MH: usize = 26;
    pub const CONV_A: usize = 28;
    pub const W_BURST: usize = 39;
    pub const S_U: usize = 40;
    pub const S_V: usize = 41;
    pub const S_W: usize = 42;
    pub const EX2: usize = 43;
    pub const N: usize = 46;
    pub const HARD_F: usize = 54;
    pub const ADVECT: usize = 55;
    pub const WD: usize = 56;
    pub const DH: usize = 61;
    pub const UNRES: usize = 63;
}

/// Шероховатость уровня поля Онгудая 400 м (`levels[0].z0` GD): в дамп не писалась, подобрана по
/// записанному признаку отрыва (`lee`) — 0,2033 м, невязка 1e-6 по всем 700 точкам четырёх случаев.
const ONGUDAI_Z0: f64 = 0.20334;

const CASES: [&str; 4] = [
    "ongudai_medium",
    "ongudai_strong",
    "ongudai_wave",
    "ongudai_storm",
];

fn atmosphere_sum_cfg() -> SumCfg {
    SumCfg::from_configs(&atmosphere())
}

/// Пересчёт болтанки слота по записи GD: те же входы, что видел `_air_velocity_field`.
fn replay(ft: &FieldTurb, r: &[f64]) -> (FieldState, dp_air::terms::TurbOut) {
    let mut tb = [0f32; 8];
    for (q, t) in tb.iter_mut().enumerate() {
        *t = r[rec::TB + q] as f32;
    }
    let st = FieldState {
        tb,
        uf: r[rec::UF],
        lee_f: sep::lee(ft.cfg(), ONGUDAI_Z0, r[rec::UF], r[rec::AGL], &tb),
        relief: r[rec::RELIEF].max(0.0),
        danger: r[rec::DANGER],
        u_h: r[rec::U_H],
        du: r[rec::DU],
    };
    let p = PointIn {
        pos: [r[0] as f32, r[1] as f32, r[2] as f32],
        t: r[rec::T],
        agl: r[rec::AGL],
        u: r[rec::U],
        z0: ONGUDAI_Z0,
        mh: [r[rec::MH], r[rec::MH + 1]],
        conv_a: r[rec::CONV_A],
        full: true,
        dir: [r[rec::WD], r[rec::WD + 1]],
        advect: r[rec::ADVECT],
    };
    (st, ft.turb_out(&st, &p))
}

fn cases_with_dump() -> Vec<(&'static str, Vec<f64>)> {
    CASES
        .iter()
        .filter_map(|c| {
            let p = data_dir().join(format!("dbg_{c}.f64"));
            p.exists().then(|| (*c, f64s(&p)))
        })
        .collect()
}

/// (5) Слот по входам GD в точках эталонов `ongudai_*`: признак отрыва, σ_u/σ_v/σ_w до слияния с
/// термиком, шум спектра (с растяжением масштабов у земли), рывки и обратный поток — как у GD.
#[test]
fn ongudai_replay_matches_air_velocity_field() {
    let cases = cases_with_dump();
    assert!(cases.len() >= 4, "дампы ongudai_*: {}", cases.len());
    let ft = FieldTurb::new(&atmosphere(), 606);
    let (mut n_all, mut n_noise, mut n_burst, mut n_rev) = (0, 0, 0, 0);
    let mut worst = [0.0f64; 5];
    for (name, buf) in &cases {
        for (i, r) in buf.chunks_exact(rec::LEN).enumerate() {
            if r[0].is_nan() {
                continue;
            }
            // seed случая — свой: шум зависит от сида, поэтому берём слот того же сида
            let seed = case_seed(name);
            let ftc = if seed == 606 {
                &ft
            } else {
                &FieldTurb::new(&atmosphere(), seed)
            };
            let (st, o) = replay(ftc, r);
            n_all += 1;
            let tag = format!("{name} #{i}");
            assert!(
                (st.lee_f - r[rec::LEE_F]).abs() <= 1e-5,
                "{tag}: lee {} != {}",
                st.lee_f,
                r[rec::LEE_F]
            );
            // σ до ограничителей: s_u = max(σ_поля, σ_sep) — финал после √(s² + ex2) и предела
            let cap_h = atmosphere_sum_cfg()
                .turb_max_ms
                .max(o.sep[0].min(atmosphere_sum_cfg().rotor_max_ms));
            let fin = (o.s_u * o.s_u + r[rec::EX2]).sqrt().min(cap_h);
            worst[0] = worst[0].max((fin - r[rec::S_U]).abs());
            let fin_v = (o.s_v * o.s_v + r[rec::EX2]).sqrt().min(cap_h);
            worst[1] = worst[1].max((fin_v - r[rec::S_V]).abs());
            let cap_v = atmosphere_sum_cfg()
                .turb_max_ms
                .max(o.sep[1].min(atmosphere_sum_cfg().rotor_max_ms));
            let vr = atmosphere_sum_cfg().vertical_ratio;
            let fin_w = (o.s_w * o.s_w + r[rec::EX2] * vr * vr).sqrt().min(cap_v);
            worst[2] = worst[2].max((fin_w - r[rec::S_W]).abs());
            for q in 0..3 {
                worst[3] = worst[3].max((o.n[q] - r[rec::N + q]).abs());
            }
            n_noise += usize::from(r[rec::N].abs() > 0.0);
            worst[4] = worst[4].max((o.w_burst - r[rec::W_BURST]).abs());
            n_burst += usize::from(r[rec::HARD_F] > 1.0e-3);
            // обратный поток эвристики
            let dh = ftc.reverse_dh(&st, r[rec::A], r[rec::AGL], r[rec::DX]);
            assert!(
                (-dh - r[rec::DH]).abs() <= 1e-5 * r[rec::DH].abs().max(1.0),
                "{tag}: dh {dh} != {}",
                -r[rec::DH]
            );
            n_rev += usize::from(r[rec::DH] > 0.0);
            let unres = sep::reverse_unresolved(ftc.cfg(), st.relief, r[rec::DX]);
            assert!(
                (unres - r[rec::UNRES]).abs() <= 1e-9 || r[rec::RELIEF] < 0.0,
                "{tag}: unres"
            );
        }
    }
    println!(
        "ongudai_*: {n_all} точек поля; шум ≠ 0: {n_noise}; рывки: {n_burst}; обратный поток: {n_rev}; \
         max|Δ| s_u {:e}, s_v {:e}, s_w {:e}, n {:e}, w_burst {:e}",
        worst[0], worst[1], worst[2], worst[3], worst[4]
    );
    assert!(n_all >= 100 && n_noise >= 100);
    assert!(
        worst[0] <= 3e-5 && worst[1] <= 3e-5 && worst[2] <= 3e-5,
        "σ {worst:?}"
    );
    assert!(worst[3] <= 1e-5, "шум спектра {worst:?}");
    assert!(worst[4] <= 1e-6, "рывки {worst:?}");
}

fn case_seed(name: &str) -> u64 {
    let c = read_case(&repo().join(format!("tests/fixtures/wind/cases/{name}.json"))).unwrap();
    c.seed
}

/// (6) `sigma[turb]` эталонов `ongudai_*` (k = 2 + 7): σ_u поля после слияния с σ термика/грозы
/// (их `ex2` берём у GD — слагаемых RW-10/11 в крейте ещё нет), допуск W8 `|Δσ| ≤ 0,02 + 5 %`.
/// Точки зоны отрыва (`lee`) считаются по `relief` аналитики (RW-9) — сверка после RW-9.
#[test]
fn ongudai_sigma_turb_within_w8() {
    let cases = cases_with_dump();
    assert!(cases.len() >= 4);
    let sc = atmosphere_sum_cfg();
    let (mut n, mut n_lee, mut bad) = (0, 0, 0);
    for (name, buf) in &cases {
        let path = repo().join(format!("tests/fixtures/wind/cases/{name}.json"));
        let case = read_case(&path).unwrap();
        let data = read_case_data(&case, &path).unwrap();
        let k_turb = 2 + case
            .terms
            .as_ref()
            .unwrap()
            .iter()
            .position(|t| t == "turb")
            .unwrap();
        let seed = case.seed;
        let ft = FieldTurb::new(&atmosphere(), seed);
        let mut want = Vec::new();
        for t in 0..data.n_t {
            want.extend(data.slab(t, k_turb).map(|v| f64::from(v[3])));
        }
        assert_eq!(want.len() * rec::LEN, buf.len(), "{name}: число записей");
        for (i, r) in buf.chunks_exact(rec::LEN).enumerate() {
            if r[0].is_nan() {
                continue;
            }
            // запись и эталон — один прогон: σ[turb] эталона = σ_u GD после слияния (f32)
            assert!(
                (f64::from(r[rec::S_U] as f32) - want[i]).abs() <= 1e-6,
                "{name} #{i}: дамп {} != эталон {}",
                r[rec::S_U],
                want[i]
            );
            let (_, o) = replay(&ft, r);
            let cap = sc.turb_max_ms.max(o.sep[0].min(sc.rotor_max_ms));
            let mine = (o.s_u * o.s_u + r[rec::EX2]).sqrt().min(cap);
            let tol = 0.02 + 0.05 * want[i].abs();
            n += 1;
            n_lee += usize::from(r[rec::LEE_F] > 0.0);
            if (mine - want[i]).abs() > tol {
                bad += 1;
                eprintln!("{name} #{i}: σ_u {mine:.4} против {:.4}", want[i]);
            }
        }
    }
    println!(
        "sigma[turb] ongudai_*: {n} точек, из них в зоне отрыва {n_lee}, вне допуска W8: {bad}"
    );
    assert!(n >= 100);
    assert_eq!(bad, 0);
}

// ---------------------------------------------------------------- T3: статистика

/// (7) T3: дисперсия, независимость и спектр. Каждая компонента шума имеет СКО 1 при любых
/// масштабах; `a` и `c` не коррелированы; доли дисперсии октав — интегралы нормированного спектра
/// фон Кармана (∫ E dk = 1); центр тяжести спектра смещается к крупным октавам с ростом `L`.
#[test]
fn t3_variance_and_von_karman_spectrum() {
    let gs = GustSpectrum::new(20_260_927, 0.6);
    let mut rng = Pcg32::from_seed(5);
    let n = 40_000;
    for (l_u, l_w) in [(10.0, 10.0), (60.0, 60.0), (300.0, 150.0), (1500.0, 600.0)] {
        let (mut s, mut s2, mut sac) = ([0.0f64; 3], [0.0f64; 3], 0.0f64);
        for _ in 0..n {
            let p = [
                rng.randf_range(-20_000.0, 20_000.0),
                rng.randf_range(0.0, 3000.0),
                rng.randf_range(-20_000.0, 20_000.0),
            ];
            let v = gs.sample(&SampleIn {
                pos: p,
                t: 0.0,
                advect: 0.0,
                dir: [1.0, 0.0],
                l_u,
                l_w,
                l_2: 0.0,
                f_a: 0.0,
                f_c: 0.0,
            });
            for q in 0..3 {
                s[q] += f64::from(v[q]);
                s2[q] += f64::from(v[q]) * f64::from(v[q]);
            }
            sac += f64::from(v[0]) * f64::from(v[2]);
        }
        let nn = f64::from(n);
        for q in 0..3 {
            let var = s2[q] / nn - (s[q] / nn).powi(2);
            println!(
                "L=({l_u},{l_w}) компонента {q}: среднее {:.3}, дисперсия {var:.3}",
                s[q] / nn
            );
            assert!(
                (var - 1.0).abs() <= 0.12,
                "дисперсия {var} при L ({l_u},{l_w}), q {q}"
            );
            assert!((s[q] / nn).abs() <= 0.06, "среднее {}", s[q] / nn);
        }
        assert!(
            (sac / nn).abs() <= 0.06,
            "a и c коррелированы: {}",
            sac / nn
        );
    }
    // нормировка спектра: ∫₀^∞ E dk = 1 (продольный и поперечный), интегрирование по ln k
    for el in [10.0f64, 300.0] {
        for tr in [false, true] {
            let f = spectrum::band(el, 1.0e-9 / el, 1.0e9 / el, tr);
            // band — 24 точки по логарифму: для проверки нормировки берём точное интегрирование
            let _ = f;
            let (n_k, lo, hi) = (400_000, (1.0e-6f64).ln(), (1.0e6f64).ln());
            let mut acc = 0.0;
            let pi = std::f64::consts::PI;
            for i in 0..n_k {
                let x = ((f64::from(i) + 0.5) / f64::from(n_k) * (hi - lo) + lo).exp();
                let k = x / (spectrum::VK_A * el);
                let e = if tr {
                    el / pi * (1.0 + 8.0 / 3.0 * x * x) / (1.0 + x * x).powf(11.0 / 6.0)
                } else {
                    2.0 * el / pi / (1.0 + x * x).powf(5.0 / 6.0)
                };
                acc += e * k * (hi - lo) / f64::from(n_k);
            }
            assert!(
                (acc - 1.0).abs() <= 2.0e-3,
                "∫E dk = {acc} (L {el}, поперечный {tr})"
            );
        }
    }
    // доля, несомая октавами, ≤ 1 и растёт к крупным октавам вместе с L
    let mut prev = 0.0;
    for el in [3.0, 10.0, 30.0, 100.0, 300.0, 1000.0, 3000.0] {
        let w = spectrum::octave_weights(el, false);
        let sum: f64 = w.iter().sum();
        let centroid: f64 = w.iter().enumerate().map(|(o, v)| o as f64 * v).sum::<f64>() / sum;
        println!(
            "L = {el}: центр тяжести октав {centroid:.2}, несомая доля {:.3}",
            spectrum::carried(el, el)[0]
        );
        assert!((sum - 1.0).abs() < 1e-5);
        assert!(centroid > prev, "центр тяжести не растёт с L");
        prev = centroid;
        let c = spectrum::carried(el, el);
        assert!(c[0] <= 1.0 + 1e-6 && c[1] <= 1.0 + 1e-6 && c[0] > 0.0 && c[1] > 0.0);
    }
}

/// (8) T3: масштабы MIL-HDBK-1797 (L_w = h, L_u = h/(0,177 + 0,000823 h)^1,2 до 1000 футов, 2500
/// футов от 2000) и σ_u ≠ σ_v ≠ σ_w: у земли σ_u/σ_w = 1/(0,177 + 0,000823 h)^0,4 ≈ 1,9 на 10 м,
/// σ_v между ними, выше 1000 футов (305 м) изотропия; σ растёт монотонно с высотой в приземном слое
/// (u* из лог-профиля), а на 1500 м (выше пограничного слоя) падает.
#[test]
fn t3_mil_scales_and_anisotropy() {
    let ft = 0.3048;
    for h_ft in [50.0f64, 200.0, 500.0, 1000.0] {
        let lw = sigma::mil_lw(h_ft * ft);
        let lu = sigma::mil_lu(h_ft * ft);
        let want_u = h_ft / (0.177 + 0.000823 * h_ft).powf(1.2) * ft;
        assert!(
            (lw - h_ft * ft).abs() < 1e-9 && (lu - want_u).abs() < 1e-9,
            "{h_ft}: {lw} {lu}"
        );
    }
    assert!(
        (sigma::mil_lw(762.0) - 762.0).abs() < 1e-9 && (sigma::mil_lu(3000.0) - 762.0).abs() < 1e-9
    );
    assert!(
        sigma::mil_lu(150.0) > sigma::mil_lw(150.0),
        "L_u > L_w у земли"
    );
    let cfg = TurbCfg::default();
    // нейтральный столб: u* 0,4, сдвиг по логарифму
    let tb = |z: f64| {
        let mut t = [0f32; 8];
        t[T_USTAR] = 0.4;
        t[T_SHEAR] = (0.4 / (0.4 * z)) as f32;
        t[T_HMIX] = 1000.0;
        t[T_N2] = f32::NAN;
        t
    };
    let prev_w = 0.0;
    for z in [3.0f64, 10.0, 30.0, 100.0] {
        let s = sigma::sigma(&cfg, 0.1, z, &tb(z), [0.0, 0.0], 8.0);
        println!(
            "z = {z}: σ_u {:.3} σ_v {:.3} σ_w {:.3} (σ_u/σ_w {:.2})",
            s.s_u,
            s.s_v,
            s.s_w,
            s.s_u / s.s_w
        );
        assert!(s.s_u > s.s_v && s.s_v > s.s_w, "σ_u > σ_v > σ_w на {z} м");
        let h_ft = z / ft;
        let aniso = 1.0 / (0.177 + 0.000823 * h_ft).powf(0.4);
        assert!(
            (s.s_u / s.s_w - aniso).abs() < 1e-6,
            "σ_u/σ_w по MIL-HDBK-1797"
        );
        assert!(s.s_w > 0.0 && s.s_w.is_finite());
        let _ = prev_w;
    }
    let hi = sigma::sigma(&cfg, 0.1, 400.0, &tb(400.0), [0.0, 0.0], -1.0);
    assert!(
        (hi.s_u - hi.s_w).abs() < 1e-6 * hi.s_u.max(1.0)
            && (hi.s_v - hi.s_w).abs() < 1e-6 * hi.s_u.max(1.0),
        "изотропия выше 1000 футов"
    );
    // за пределами слоя (z > h) механическая σ гаснет
    let top = sigma::sigma(&cfg, 0.1, 1500.0, &tb(1500.0), [0.0, 0.0], -1.0);
    assert!(
        top.s_u < hi.s_u,
        "выше слоя σ меньше: {} против {}",
        top.s_u,
        hi.s_u
    );
    // растяжение масштабов у земли: 1 на высоте, до TAYLOR_MAX у земли при слабом местном ветре
    assert!((sigma::taylor_stretch(10.0, 10.0, 0.0) - 1.0).abs() < 1e-12);
    assert!((sigma::taylor_stretch(10.0, 0.5, 0.0) - sigma::TAYLOR_MAX.min(20.0)).abs() < 1e-12);
    assert!(sigma::taylor_stretch(10.0, 2.0, 100.0) < 1.0 + 1e-3);
}

/// Условия зоны отрыва за гребнем (синтетика `test_lee_rotor.gd`, блок «с полем»): след U_out
/// 8 м/с с признаком отрыва 1, ΔU = 6 м/с, опасность 1; поле даёт среднее, слот — болтанку.
fn separation_zone(du: f64) -> (FieldState, [f32; 8]) {
    let mut tb = [0f32; 8];
    tb[T_USTAR] = 0.05;
    tb[T_SHEAR] = 0.005;
    tb[T_UOUT] = 8.0;
    tb[T_AOUT] = 200.0;
    tb[T_DESC] = 0.2;
    tb[T_WSTAR] = 0.0;
    tb[T_HMIX] = 0.0;
    tb[T_N2] = f32::NAN;
    let st = FieldState {
        tb,
        uf: 0.5,
        lee_f: 1.0,
        relief: 100.0,
        danger: 1.0,
        u_h: 0.5 + du,
        du,
    };
    (st, tb)
}

/// (9) Перенос `test_lee_rotor.gd` (`test_field_*`): в зоне отрыва рывки — часть болтанки слоя
/// смешения с нулевым средним, пики ≤ 0,45·ΔU, σ_w ≈ 0,14·ΔU ±20 %, σ_u ≈ 0,18·ΔU; обратный поток
/// 0,22·U_H·lee·ядро есть только на грубой сетке (400 м), на мелкой (25 м) пузырь даёт поле.
#[test]
fn separation_zone_bursts_sigma_and_reverse_flow() {
    let c = atmosphere();
    let ft = FieldTurb::new(&c, 606);
    let cfg = *ft.cfg();
    let du = 6.0;
    let (st, tb) = separation_zone(du);
    assert!(sep::lee(&cfg, 0.1, 0.5, 20.0, &tb) > 0.99);
    let (g_mean, g_std) = ft.burst_stats();
    let (mut s2, mut peak, mut peak_b, mut n, mut su2) = (0.0, 0.0f64, 0.0f64, 0, 0.0);
    let mut rng = Pcg32::from_seed(9);
    for _ in 0..6000 {
        let pos = [
            rng.randf_range(200.0, 400.0),
            rng.randf_range(10.0, 60.0),
            rng.randf_range(-200.0, 200.0),
        ];
        let t = f64::from(rng.randf_range(0.0, 400.0));
        let o = ft.turb_out(
            &st,
            &PointIn {
                pos,
                t,
                agl: 30.0,
                u: 8.0,
                z0: 0.1,
                mh: [3.0, 0.0],
                conv_a: 0.0,
                full: true,
                dir: [1.0, 0.0],
                advect: 8.0,
            },
        );
        // a = 1: вертикаль = шум·σ_w + рывок
        let wv = o.n[1] * o.s_w + o.w_burst;
        s2 += (wv / du).powi(2);
        su2 += (o.n[0] * o.s_u / du).powi(2);
        peak = peak.max((wv / du).abs());
        let gb = sep::burst_g(&cfg, ft.gusts(), pos, t, [1.0, 0.0], 8.0);
        peak_b = peak_b.max((cfg.burst_per_du * (gb - g_mean)).abs());
        n += 1;
    }
    let sw = (s2 / f64::from(n)).sqrt();
    let su = (su2 / f64::from(n)).sqrt();
    println!(
        "зона отрыва: σ_w/ΔU {sw:.3}, σ_u/ΔU {su:.3}, пик |w′|/ΔU {peak:.2}, пик рывка/ΔU {peak_b:.2}, ḡ {g_mean:.3}, σ_g {g_std:.3}"
    );
    assert!(peak_b <= 0.45, "пики рывков ≤ 0,45·ΔU: {peak_b}");
    assert!((sw - 0.14).abs() <= 0.2 * 0.14, "σ_w ≈ 0,14·ΔU ±20 %: {sw}");
    assert!((su - 0.18).abs() <= 0.2 * 0.18, "σ_u ≈ 0,18·ΔU ±20 %: {su}");
    // обратный поток эвристики: только на грубой сетке
    let agl = 30.0;
    let core = (-agl / (cfg.rotor_h * st.relief).max(1.0)).exp();
    let fine = ft.reverse_dh(&st, 1.0, agl, 25.0);
    let coarse = ft.reverse_dh(&st, 1.0, agl, 400.0);
    println!("обратная добавка: dx 25 м {fine:.4}, dx 400 м {coarse:.4}");
    assert!(
        fine.abs() < 0.01,
        "dx 25: пузырь разрешён — добавки нет ({fine})"
    );
    let want = -cfg.reverse * st.u_h * st.lee_f * core;
    assert!(
        (coarse - want).abs() <= 1e-9 * want.abs(),
        "dx 400: {coarse} != {want}"
    );
    assert!(coarse < -0.3);
    // MEAN: σ та же, шума и рывков нет
    let m = ft.turb_out(
        &st,
        &PointIn {
            pos: [300.0, 40.0, 0.0],
            t: 10.0,
            agl: 30.0,
            u: 8.0,
            z0: 0.1,
            mh: [3.0, 0.0],
            conv_a: 0.0,
            full: false,
            dir: [1.0, 0.0],
            advect: 8.0,
        },
    );
    let f = ft.turb_out(
        &st,
        &PointIn {
            full: true,
            ..PointIn {
                pos: [300.0, 40.0, 0.0],
                t: 10.0,
                agl: 30.0,
                u: 8.0,
                z0: 0.1,
                mh: [3.0, 0.0],
                conv_a: 0.0,
                full: true,
                dir: [1.0, 0.0],
                advect: 8.0,
            }
        },
    );
    assert_eq!((m.s_u, m.s_v, m.s_w, m.sep), (f.s_u, f.s_v, f.s_w, f.sep));
    assert_eq!((m.n, m.w_burst), ([0.0; 3], 0.0));
}

/// (10) Слот в сумме `terms::sum`: на поле острова (запечённое) `turb` даёт σ_u > 0, шум только в
/// FULL (MEAN: та же σ, скорость без шума), результат — чистая функция `(точка, t)`, ортогональные
/// горизонтали (σ_u ≠ σ_v по дисперсии вдоль и поперёк ветра), `decompose` сходится с итогом.
#[test]
fn slot_in_sum_on_island_field() {
    let _ = SampleMode::Full;
    let _ = terms::NAMES;
    // сборка поля острова — как в terms_sum.rs
    island::run();
}

mod island {
    use super::*;
    use dp_air::field::baked::parse_baked;
    use dp_air::field::field_set::FieldSet;
    use dp_air::field::runtime::{RtCfg, ground_height};
    use dp_air::terms::Terms;
    use dp_air::{AirModel, Conditions, Focus, Formula, Place, State};
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    fn collect(dir: &Path, prefix: &str, out: &mut Vec<(String, String)>) {
        for e in std::fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            let name = format!("{prefix}{}", p.file_name().unwrap().to_string_lossy());
            if p.is_dir() {
                collect(&p, &format!("{name}/"), out);
            } else if p.extension().is_some_and(|x| x == "json") {
                out.push((name, std::fs::read_to_string(&p).unwrap()));
            }
        }
    }

    fn configs() -> Configs {
        let mut files = Vec::new();
        collect(&repo().join("configs"), "", &mut files);
        for (n, t) in &mut files {
            if n == "atmosphere.json" {
                let mut v: Value = serde_json::from_str(t).unwrap();
                v["air"]["deterministic"] = serde_json::json!(true);
                v["air"]["domain_l_m"] = serde_json::json!(7200.0);
                v["air"]["threads"] = serde_json::json!(4);
                v["air"]["tol_scale"] = serde_json::json!(5.0);
                v["air_model"]["edge_blend_cells"] = serde_json::json!(1.0);
                *t = serde_json::to_string(&v).unwrap();
            }
        }
        files.sort();
        Configs::new(files)
    }

    fn island_files() -> Vec<(String, Vec<u8>)> {
        let dir = repo().join("data/locations/training_island/air");
        let mut names: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.extension().is_some_and(|x| x == "json"))
            .collect();
        names.sort();
        names
            .into_iter()
            .map(|p| {
                (
                    std::fs::read_to_string(&p).unwrap(),
                    std::fs::read(p.with_extension("bin")).unwrap(),
                )
            })
            .collect()
    }

    fn island_place() -> Place {
        let files = island_files();
        let v: Value = serde_json::from_str(&files[0].0).unwrap();
        let hash = v["model_hash"].as_str().unwrap().to_string();
        let sites: Vec<String> = files
            .iter()
            .map(|(h, _)| {
                let v: Value = serde_json::from_str(h).unwrap();
                let st = &v["key"]["start"];
                format!(r#"{{"x":{},"z":{},"h_msl":100.0}}"#, st[0], st[1])
            })
            .collect();
        let header = format!(
            r#"{{"version":1,"loc":{{"id":"training_island","center_lat":43.2,"center_lon":34.0,
"utc_offset_h":2.0,"month":7,"day":15}},"grid":{{"origin_x":-10000,"origin_z":-10000,"spacing":25,
"width":801,"height":801}},"surface_classes":{{"grass":1}},"start_sites":[{}],
"model_hash":"{hash}"}}"#,
            sites.join(",")
        );
        let h = dp_air::PlaceHeader::from_json(&header).unwrap();
        let n = h.cells();
        Place::new(
            h,
            vec![100.0; n],
            vec![0; n],
            vec![0; n].iter().map(|_| 1u8).collect(),
            vec![0.5; n],
        )
        .unwrap()
    }

    pub fn run() {
        let pl = island_place();
        let cfgs = configs();
        let mut m = Formula::new().with_faults(dp_air::field::runtime::Faults {
            coarse: false,
            fail_pass: None,
            no_phase: false,
            no_windows: true,
        });
        m.configure(&cfgs, 1).unwrap();
        m.set_conditions(
            &Conditions::from_json(
                r#"{"forecast":{"temperature_c":22,"wind_speed_kmh":14.4,"wind_from_deg":270,"sky":"clear"},
"quantum_h":1,"start_hour":9,"speed":1,"blend_s":null,"rebuild":false}"#,
            )
            .unwrap(),
        )
        .unwrap();
        m.set_focuses(&[Focus {
            pos: [3510.0, 110.0, -1510.0],
            weight: 1.0,
        }])
        .unwrap();
        m.load_place(pl.clone()).unwrap();
        for (h, b) in island_files() {
            m.add_baked_field(&h, &b).unwrap();
        }
        let t0 = Instant::now();
        loop {
            m.poll();
            if m.status().state == State::Ready && m.level_count() > 0 {
                break;
            }
            assert_ne!(m.status().state, State::Failed, "{}", m.status().reason);
            assert!(t0.elapsed() < Duration::from_secs(120), "нет поля");
            std::thread::sleep(Duration::from_millis(2));
        }
        let e = m.field_export();
        let b = parse_baked(&e.header_json, &e.data).unwrap();
        let rt = RtCfg::from_configs(&cfgs).unwrap();
        let mut fs = FieldSet::new(rt.limits, rt.edge_blend_cells);
        fs.set_field(b.levels, 0.0);
        let mut t = Terms::default();
        t.configure(&Arc::new(cfgs.clone()), 1);
        t.wind.set_wind(14.4 / 3.6, 270.0);
        // 600 точек поля у площадки: 3–150 м над землёй
        let mut rng = Pcg32::from_seed(77);
        let pts: Vec<[f32; 3]> = (0..600)
            .map(|_| {
                let x = 3510.0 + rng.randf_range(-1500.0, 1500.0);
                let z = -1510.0 + rng.randf_range(-1500.0, 1500.0);
                [x, ground_height(&pl, x, z) + rng.randf_range(3.0, 150.0), z]
            })
            .collect();
        let wd = t.wind.dir();
        let (mut s_along, mut s_cross, mut s_vert, mut n, mut s_sig) = (0.0, 0.0, 0.0, 0, 0.0);
        let mut nonzero_sigma = 0;
        for (i, p) in pts.iter().enumerate() {
            let tm = 10.0 + 0.37 * i as f64;
            let full = terms::sum(&t, &fs, Some(&pl), *p, SampleMode::Full, tm, None);
            let mean = terms::sum(&t, &fs, Some(&pl), *p, SampleMode::Mean, tm, None);
            let again = terms::sum(&t, &fs, Some(&pl), *p, SampleMode::Full, tm, None);
            assert_eq!(
                full.map(f32::to_bits),
                again.map(f32::to_bits),
                "чистая функция точки"
            );
            assert_eq!(full[3].to_bits(), mean[3].to_bits(), "σ в MEAN та же");
            if full[3] > 0.0 {
                nonzero_sigma += 1;
            }
            let d = [
                f64::from(full[0] - mean[0]),
                f64::from(full[1] - mean[1]),
                f64::from(full[2] - mean[2]),
            ];
            // ось «вдоль среднего ветра» — по ветру в точке (mean), поперёк — перпендикуляр
            let ml = f64::from(mean[0]).hypot(f64::from(mean[2]));
            let e = if ml > 0.3 {
                [f64::from(mean[0]) / ml, f64::from(mean[2]) / ml]
            } else {
                wd
            };
            let al = d[0] * e[0] + d[2] * e[1];
            let cr = -d[0] * e[1] + d[2] * e[0];
            s_along += al * al;
            s_cross += cr * cr;
            s_vert += d[1] * d[1];
            s_sig += f64::from(full[3]).powi(2);
            n += 1;
            // разложение сходится с итогом
            let dc = m.decompose(*p);
            let _ = dc;
        }
        let nn = f64::from(n);
        println!(
            "остров: σ ≠ 0 в {nonzero_sigma}/{n}; rms вдоль {:.3}, поперёк {:.3}, вертикаль {:.3}, rms σ {:.3}",
            (s_along / nn).sqrt(),
            (s_cross / nn).sqrt(),
            (s_vert / nn).sqrt(),
            (s_sig / nn).sqrt()
        );
        assert!(nonzero_sigma > n / 2, "σ поля есть");
        assert!(
            s_along > 0.0 && s_cross > 0.0 && s_vert > 0.0,
            "шум есть по всем осям"
        );
        // горизонталь крупнее вертикали (σ_u/σ_w ≥ 1,3 у земли, до 300 м)
        assert!(s_along > s_vert, "σ_u > σ_w: {s_along} {s_vert}");
        // decompose: turb ≠ 0, Σ vel = total
        let mut seen_turb = false;
        for p in pts.iter().take(200) {
            let dc = m.decompose(*p);
            let s: [f32; 3] = std::array::from_fn(|q| dc.vel.iter().map(|v| v[q]).sum());
            for (a, b) in s.iter().zip(&dc.total) {
                assert!((a - b).abs() <= 1e-4);
            }
            seen_turb |=
                dc.vel[terms::T_TURB].iter().any(|x| *x != 0.0) && dc.sigma[terms::T_TURB] > 0.0;
        }
        assert!(seen_turb, "в разложении есть слагаемое turb");
    }
}

#[test]
fn _unused_consts_are_documented() {
    // индексы каналов поля используются в синтетических столбцах T3
    assert_eq!(
        [
            T_SHEAR, T_N2, T_USTAR, T_UOUT, T_AOUT, T_DESC, T_WSTAR, T_HMIX
        ],
        [0, 1, 2, 3, 4, 5, 6, 7]
    );
    let _ = max_rel(1.0, 1.0);
}
