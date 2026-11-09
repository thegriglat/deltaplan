//! LT-9: контракт LTM v1 (`docs/contracts/lee-turb.md`) — болтанка за гребнем на пути с полем.
//!
//! (а) на пути с полем (a = 1) за гребнем r > 0 и ΔU > 0 там, где lee_f > 0 (поле Онгудая);
//! (б) `sep_sigma` = (0,166; 0,130; 0,153)·ΔU по конфигу; (в) w_sep = 1 — член l·|∂U/∂z| не входит,
//! w_sep = 0 — прежний σ побитно; (г) ключи в `configs/atmosphere.json` с `_doc`.
use dp_air::field::field_set::FieldSet;
use dp_air::field::runtime::ground_height;
use dp_air::field::solved::parse_solved;
use dp_air::field::wind_field::{
    Limits, T_AOUT, T_DESC, T_HMIX, T_N2, T_SHEAR, T_UOUT, T_USTAR, T_WSTAR,
};
use dp_air::fixtures::read_place;
use dp_air::terms::turb::sigma::{self, TurbCfg};
use dp_air::terms::turb::{FieldTurb, sep};
use dp_air::terms::Ctx;
use dp_air::{AirModel, Conditions, Configs, Formula, SampleMode, State};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn atmosphere_json() -> Value {
    serde_json::from_str(&std::fs::read_to_string(repo().join("configs/atmosphere.json")).unwrap())
        .unwrap()
}

fn atmosphere() -> Configs {
    Configs::new(vec![("atmosphere".into(), atmosphere_json().to_string())])
}

#[test]
fn keys_have_docs_and_values() {
    let a = atmosphere_json();
    let l = &a["lee"];
    for k in [
        "field_sigma_u_per_du",
        "field_sigma_v_per_du",
        "field_sigma_w_per_du",
        "field_burst_per_du",
        "field_wall_shear_off_agl_per_relief",
    ] {
        assert!(!l[k].is_null(), "lee.{k}");
        let d = l[format!("{k}_doc")].as_str().unwrap_or("");
        assert!(d.contains("docs/research/lee_turb.md"), "lee.{k}_doc без источника");
    }
    assert_eq!(l["field_sigma_u_per_du"], json!(0.166));
    assert_eq!(l["field_sigma_v_per_du"], json!(0.130));
    assert_eq!(l["field_sigma_w_per_du"], json!(0.153));
    assert_eq!(l["field_wall_shear_off_agl_per_relief"], json!([0.75, 1.0]));
    let c = TurbCfg::from_configs(&atmosphere());
    assert_eq!((c.sep_su, c.sep_sv, c.sep_sw), (0.166, 0.130, 0.153));
    assert_eq!(c.wall_off, (0.75, 1.0));
    assert!((c.burst_per_du - 3.0 * c.sep_sw).abs() < 2.0e-3, "рывки = 3σ_w");
}

#[test]
fn sep_sigma_follows_config() {
    let c = TurbCfg::from_configs(&atmosphere());
    let du = 6.0;
    let s = sep::sep_sigma(&c, du);
    for (g, k) in s.iter().zip([0.166, 0.130, 0.153]) {
        assert!((g - k * du).abs() < 1.0e-5, "{g} против {}", k * du);
    }
    assert_eq!(sep::sep_sigma(&c, 0.0), [0.0; 3]);
}

fn tb_shear() -> [f32; 8] {
    // слабый u*, сдвиг поля большой: член l·|∂U/∂z| определяет механику
    let mut tb = [0f32; 8];
    tb[T_USTAR] = 0.05;
    tb[T_SHEAR] = 0.2;
    tb[T_UOUT] = 8.0;
    tb[T_AOUT] = 200.0;
    tb[T_DESC] = 0.2;
    tb[T_WSTAR] = 0.0;
    tb[T_HMIX] = 0.0;
    tb[T_N2] = f32::NAN;
    tb
}

#[test]
fn wall_shear_term_removed_by_w_sep() {
    let c = TurbCfg::from_configs(&atmosphere());
    let tb = tb_shear();
    let z = 30.0;
    let s0 = sigma::sigma(&c, 0.1, z, &tb, [0.0, 0.0], 3.0, 0.0);
    let s1 = sigma::sigma(&c, 0.1, z, &tb, [0.0, 0.0], 3.0, 1.0);
    // w_sep = 0: прежняя механика с членом l·S; w_sep = 1: только подобие u*(1 − z/h)^¾
    assert!(s0.s_w > 1.5 * s1.s_w, "{} против {}", s0.s_w, s1.s_w);
    assert!(s1.s_w > 0.0);
    // побитно: w_sep = 0 даёт тот же результат, что формула без множителя
    let again = sigma::sigma(&c, 0.1, z, &tb, [0.0, 0.0], 3.0, 0.0);
    assert_eq!(s0.s_w.to_bits(), again.s_w.to_bits());
    // половинный вес — между
    let sh = sigma::sigma(&c, 0.1, z, &tb, [0.0, 0.0], 3.0, 0.5);
    assert!(sh.s_w <= s0.s_w && sh.s_w >= s1.s_w);
}

#[test]
fn wall_shear_weight_shape() {
    let c = TurbCfg::from_configs(&atmosphere());
    let (r, dx) = (100.0, 50.0); // пузырь 280 м / 50 = 5,6 клеток: частично разрешён
    let unres = sep::reverse_unresolved(&c, r, dx);
    assert!(unres > 0.0 && unres < 1.0);
    // ниже 0,75 r — полный вес (× lee × unres), выше r — 0
    let w = |agl| sep::wall_shear_off(&c, 1.0, r, agl, dx);
    assert!((w(10.0) - unres).abs() < 1.0e-12);
    assert!(w(r) == 0.0 && w(2.0 * r) == 0.0);
    assert!(w(85.0) > 0.0 && w(85.0) < w(10.0));
    // нет превышения гребня или отрыва — веса нет
    assert_eq!(sep::wall_shear_off(&c, 1.0, 0.0, 10.0, dx), 0.0);
    assert_eq!(sep::wall_shear_off(&c, 0.0, r, 10.0, dx), 0.0);
    // пузырь разрешён (грубая сетка → мелкая): веса нет
    assert_eq!(sep::wall_shear_off(&c, 1.0, r, 10.0, 5.0), 0.0);
}

// ---------------------------------------------------------------- (а) поле Онгудая

fn collect(dir: &std::path::Path, prefix: &str, out: &mut Vec<(String, String)>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        let name = format!("{prefix}{}", p.file_name().unwrap().to_string_lossy());
        if p.is_dir() {
            collect(&p, &format!("{name}/"), out);
        } else if p.extension().is_some_and(|x| x == "json") {
            out.push((
                name.trim_end_matches(".json").to_string(),
                std::fs::read_to_string(&p).unwrap(),
            ));
        }
    }
}

/// Игровые конфиги, малая область (как `cheap` в acceptance.rs).
fn cheap_configs() -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = json!(true);
            v["air"]["domain_l_m"] = json!(7200.0);
            v["air"]["threads"] = json!(4);
            v["air"]["tol_scale"] = json!(5.0);
            v["air"]["timeout_s"] = json!(600.0);
            v["air_model"]["edge_blend_cells"] = json!(1.0);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

struct Rig {
    pl: dp_air::Place,
    fs: FieldSet,
    terms: std::sync::Arc<dp_air::terms::Terms>,
    cfgs: Configs,
}

fn rig() -> Rig {
    let cfgs = cheap_configs();
    let pl = read_place(&repo().join("tests/fixtures/wind/places/ongudai.json")).unwrap();
    // сильный ветер с запада: подветренная сторона — к востоку от гребней
    let c = Conditions::from_json(
        r#"{"preset":{"wind_speed_kmh":45,"wind_from_deg":270,"sky":"clear","temperature_c":24},
"start_hour":12,"speed":1,"blend_s":null,"rebuild":false}"#,
    )
    .unwrap();
    let mut m = Formula::new();
    m.configure(&cfgs, 1).unwrap();
    m.set_conditions(&c).unwrap();
    m.load_place(pl.clone()).unwrap();
    let t0 = Instant::now();
    loop {
        let s = m.status();
        match s.state {
            State::Ready => {
                m.poll();
                break;
            }
            State::Failed => panic!("Failed: {}", s.reason),
            _ => {}
        }
        assert!(t0.elapsed().as_secs_f64() < 900.0, "no Ready");
        std::thread::sleep(Duration::from_millis(5));
    }
    let ex = m.field_export();
    assert!(ex.version > 0, "поля нет");
    let sf = parse_solved(&ex.header_json, &ex.data).unwrap();
    let lim = Limits::default();
    let mut fs = FieldSet::new(lim, 5.0);
    fs.set_levels(FieldSet::prepare(sf.levels, lim, 5.0), 0.0);
    Rig {
        pl,
        fs,
        terms: m.terms_snapshot(),
        cfgs,
    }
}

impl Rig {
    fn ctx(&self, p: [f32; 3], g: f32) -> Option<Ctx<'_>> {
        let v = self.fs.sample(p, g);
        if v.share < 1.0 {
            return None; // только путь с полем: a = 1
        }
        let agl = f64::from(p[1] - g);
        Some(Ctx {
            pos: p,
            ground: g,
            agl,
            t: 0.0,
            mode: SampleMode::Mean,
            a: v.share,
            fw: v.v,
            u: self.terms.wind.speed_at_pos(agl, f64::from(p[1])),
            terms: &self.terms,
            fs: &self.fs,
            place: &self.pl,
        })
    }
}

/// Замер: слот `Turb` (mean + sigma = два `state`) на точках пути с поля, мкс на точку, медиана
/// из 7 повторов. `cargo test --release -p dp-air --test lee_turb_ltm timing -- --ignored --nocapture`.
#[test]
#[ignore]
fn timing_turb_slot_per_point() {
    use dp_air::terms::Turb;
    use dp_air::terms::Mid;
    let r = rig();
    let ft = FieldTurb::new(&r.cfgs, 1);
    let mut pts = Vec::new();
    for ix in -40..=40 {
        for iz in -40..=40 {
            let (x, z) = (60.0 * ix as f32, 60.0 * iz as f32);
            let g = ground_height(&r.pl, x, z);
            for agl in [8.0f32, 25.0, 60.0, 150.0] {
                pts.push([x, g + agl, z, g]);
            }
        }
    }
    let run = || {
        let mut acc = 0.0;
        let mut n = 0usize;
        let t0 = Instant::now();
        for q in &pts {
            let Some(c) = r.ctx([q[0], q[1], q[2]], q[3]) else {
                continue;
            };
            let tm = ft.mean(&c, None);
            let mid = Mid {
                v: c.fw.map(f64::from),
                analytic: None,
                turb: tm,
                thermal: None,
                extra: None,
            };
            if let Some(o) = ft.sigma(&c, &mid) {
                acc += o.s_w;
            }
            n += 1;
        }
        std::hint::black_box(acc);
        (t0.elapsed().as_secs_f64() * 1.0e6 / n as f64, n)
    };
    run();
    let mut v: Vec<f64> = (0..7).map(|_| run().0).collect();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!("TIMING мкс/точку: медиана {:.2}, min {:.2}, max {:.2}, точек {}", v[3], v[0], v[6], run().1);
}

#[test]
fn field_path_gets_relief_and_mixing_layer() {
    let r = rig();
    let (pl, fs, terms, cfgs) = (&r.pl, &r.fs, &r.terms, &r.cfgs);
    let ft = FieldTurb::new(cfgs, 1);
    let (mut n_lee, mut n_r, mut n_du, mut n_wsep) = (0, 0, 0, 0);
    let mut worst = (f64::MAX, 0.0);
    for ix in -40..=40 {
        for iz in -40..=40 {
            let (x, z) = (60.0 * ix as f32, 60.0 * iz as f32);
            let g = ground_height(pl, x, z);
            for agl in [8.0f32, 25.0, 60.0] {
                let p = [x, g + agl, z];
                let v = fs.sample(p, g);
                if v.share < 1.0 {
                    continue; // только путь с полем: a = 1
                }
                let ctx = Ctx {
                    pos: p,
                    ground: g,
                    agl: f64::from(agl),
                    t: 0.0,
                    mode: SampleMode::Mean,
                    a: v.share,
                    fw: v.v,
                    u: terms.wind.speed_at_pos(f64::from(agl), f64::from(p[1])),
                    terms,
                    fs,
                    place: pl,
                };
                // аналитика при a ≥ 1 не вызывается: am = None, как на пути с полем
                let st = ft.state(&ctx, None);
                if st.lee_f > 0.0 {
                    n_lee += 1;
                    n_r += usize::from(st.relief > 0.0);
                    n_du += usize::from(st.du > 0.0);
                    n_wsep += usize::from(st.w_sep > 0.0);
                    if st.lee_f > 0.5 && st.relief <= 0.0 {
                        worst = (st.lee_f, st.relief);
                    }
                }
            }
        }
    }
    println!("точек lee_f>0 при a=1: {n_lee}; r>0: {n_r}; ΔU>0: {n_du}; w_sep>0: {n_wsep}");
    assert!(n_lee > 50, "зоны отрыва на пути с полем нет: {n_lee}");
    assert!(worst.0 == f64::MAX, "lee_f>0,5 при r=0: {worst:?}");
    assert!(n_r * 10 >= n_lee * 8, "r>0 только в {n_r} из {n_lee}");
    assert!(n_du > 0, "ΔU = 0 всюду в зоне отрыва");
}
