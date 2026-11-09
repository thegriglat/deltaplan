//! PT-9 (PT7 v1): срезанные клетки в случаях игры — доли `vf`, `af_*` из растра места, типы по
//! `hc_type`, `cut_cells` всегда. (а) плоское место — путь с долями побитно равен пути без долей;
//! (б) Онгудай 400 м — инварианты долей и типов, общие доли mech/heat; (в) загрузка Онгудая с
//! окнами 100/50 м (`#[ignore]`, release); (г) ключ кеша `format: 2`.
//! Тяжёлые: `cargo test --release -p dp-air --test cut_game -- --include-ignored --nocapture`.
mod common;

use dp_air::field::case_build::{SolverCfg, build_solver_case};
use dp_air::field::case_prepare::{CaseOpts, build_case_with};
use dp_air::field::field_cache::{FieldCache, Miss};
use dp_air::field::place_input::{ZiCfg, build_domain_input};
use dp_air::field::runtime::*;
use dp_air::field::weather_core::{Day, Domain, WeatherConfigs, WeatherInputs, hour_at};
use dp_air::field::wind_profile::CaseProfile;
use dp_air::fixtures::read_place;
use dp_air::{AirModel, Conditions, Configs, Focus, Formula, Place, State};
use picard_rs::api::StopReason as Stop;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32};
use std::time::{Duration, Instant};

const VF_MIN: f32 = 0.05;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn collect(dir: &Path, prefix: &str, out: &mut Vec<(String, String)>) {
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

fn configs_with(patch: impl Fn(&mut Value)) -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            patch(&mut v);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

fn place(name: &str) -> Place {
    read_place(&repo().join(format!("tests/fixtures/wind/places/{name}.json"))).unwrap()
}

fn cond(preset: &str) -> Conditions {
    Conditions::from_json(&format!(
        r#"{{"preset":"{preset}","start_hour":12,"speed":1,"blend_s":null,"rebuild":false}}"#
    ))
    .unwrap()
}

/// Плоское место на нулевой высоте: рельеф на границе слоёв (`z_bot = −dz`, слой 2 начинается в 0).
fn flat_place() -> Place {
    let header = r#"{"version":1,"loc":{"id":"flat","center_lat":43.2,"center_lon":34.0,
"utc_offset_h":2.0,"month":7,"day":15},"grid":{"origin_x":-10000,"origin_z":-10000,"spacing":25,
"width":801,"height":801},"surface_classes":{"grass":1},
"start_sites":[{"x":0.0,"z":0.0,"h_msl":0.0}],"model_hash":"flat"}"#;
    let h = dp_air::PlaceHeader::from_json(header).unwrap();
    let n = h.cells();
    Place::new(h, vec![0.0; n], vec![0; n], vec![1; n], vec![0.5; n]).unwrap()
}

fn day() -> Day {
    Day {
        hour: 12.0,
        t: 295.0,
        cap: f64::INFINITY,
        h_v: 0.0,
        t_u: 290.0,
        z_u: 3.0,
        gam: 0.004,
        t_min: 0.0,
        t_res: 0.0,
        t_full: 0.0,
        dep: 1.0,
        sky_heat: 0.0,
        cover: 0.0,
        heat: 0.0,
        theta_s: 290.0,
        z_i: 1500.0,
    }
}

fn wind() -> CaseProfile {
    CaseProfile {
        sun_elev_deg: 60.0,
        class: 0,
        alpha: 0.24,
        z_sat: 0.0,
        max_profile: 1.5,
    }
}

fn job_in(cfgs: &Configs, pl: Place, c: &Conditions, focus: Option<Focus>) -> JobIn {
    let mut cfg = RtCfg::from_configs(cfgs).unwrap();
    cfg.faults = Faults {
        coarse: false,
        fail_pass: None,
        no_phase: false,
        no_windows: true,
    };
    let inputs = WeatherInputs::from_conditions(c, cfgs).unwrap();
    let rec = CondRec::new(&inputs, hour_at(c, 0.0));
    JobIn {
        weather: Some(common::real_weather()),
        cfg: Arc::new(cfg),
        configs: Arc::new(cfgs.clone()),
        place: Arc::new(pl),
        cond: c.clone(),
        rec,
        loading: true,
        focus: focus.map(|f| [f.pos[0], f.pos[2]]),
        warm: None,
        cancel: Arc::new(AtomicBool::new(false)),
        progress: Arc::new(AtomicU32::new(0)),
        stage: Arc::new(StageCounter::default()),
        cache: None,
        place_hash: Arc::new(std::sync::OnceLock::new()),
        clip: None,
        win_fail: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
    }
}

// ---------------------------------------------------------------- (а) плоское место

#[test]
fn flat_place_with_fractions_equals_the_plain_path() {
    let cfgs = configs_with(|_| {});
    let wc = WeatherConfigs::from_configs(&cfgs).unwrap();
    let zi = ZiCfg::from_configs(&cfgs).unwrap();
    let pl = flat_place();
    let dom = Domain {
        x0: -2400.0,
        y0: -2400.0,
        nx: 12,
        ny: 12,
        dx: 400.0,
    };
    let inp = build_domain_input(&pl, &wc.sh, &zi, &dom, &day()).unwrap();
    assert!(inp.cut.is_some());
    assert_eq!(inp.hc_type, inp.hc, "flat terrain on a layer boundary: hc_type = hc");
    let mut plain_inp = inp.clone();
    plain_inp.cut = None;
    let mk = |i: &dp_air::field::place_input::DomainInput| {
        let case = build_case_with(i, &wind(), 5.0, 270.0, None).unwrap();
        let planes = case.prepare().unwrap();
        let solver = build_solver_case(&planes, &case.p, &SolverCfg::new(5.0)).unwrap();
        (planes, solver)
    };
    let _ = CaseOpts { heat: false };
    let (pa, ca) = mk(&inp);
    let (pb, cb) = mk(&plain_inp);
    let mut pa_plain = pa.clone();
    pa_plain.cut = None;
    assert_eq!(pa_plain, pb, "PreparedPlanes: with fractions == without");
    assert!(ca.params.cut_cells && !cb.params.cut_cells);
    for (k, v) in &cb.arrays {
        let w = ca.arrays.get(k).unwrap_or_else(|| panic!("no {k}"));
        assert!(
            v.iter().zip(w).all(|(a, b)| a.to_bits() == b.to_bits()),
            "array {k} differs"
        );
    }
    // доли: воздух полон, грани воздуха полны
    let (nx, ny, nz) = (ca.nxh, ca.nyh, ca.nzh);
    let cell = &ca.arrays["cell"];
    let (vf, au, av, aw) = (
        &ca.arrays["vf"],
        &ca.arrays["af_u"],
        &ca.arrays["af_v"],
        &ca.arrays["af_w"],
    );
    let mut n_air = 0;
    for k in 1..nz - 1 {
        for j in 1..ny - 1 {
            for i in 1..nx - 1 {
                let q = (k * ny + j) * nx + i;
                if cell[q] == 1.0 {
                    n_air += 1;
                    assert_eq!(vf[q], 1.0);
                    for f in [au[q], au[q + 1], av[q], av[q + nx], aw[q], aw[q + nx * ny]] {
                        assert_eq!(f, 1.0);
                    }
                }
            }
        }
    }
    assert!(n_air > 0);
}

// ---------------------------------------------------------------- (б) Онгудай 400 м

#[test]
fn ongudai_400m_fractions_and_types() {
    let cfgs = configs_with(|v| {
        v["air"]["deterministic"] = json!(true);
    });
    let t0 = Instant::now();
    let job = job_in(&cfgs, place("ongudai"), &cond("strong"), None);
    let [cm, ch] = level_cases(&job).unwrap();
    eprintln!("ongudai 400 m: two cases in {:.2} s", t0.elapsed().as_secs_f64());
    assert!(cm.params.cut_cells && ch.params.cut_cells);
    assert_eq!((cm.nxh, cm.nyh, cm.nzh), (ch.nxh, ch.nyh, ch.nzh));
    for name in ["vf", "af_u", "af_v", "af_w", "cell", "tu", "tv", "tw"] {
        let (a, b) = (&cm.arrays[name], &ch.arrays[name]);
        assert!(
            a.iter().zip(b).all(|(x, y)| x.to_bits() == y.to_bits()),
            "{name}: mech != heat"
        );
    }
    let (nx, ny, nz) = (cm.nxh, cm.nyh, cm.nzh);
    let (nyx, n3) = (nx * ny, nx * ny * nz);
    let g = |n: &str| &cm.arrays[n];
    let (cell, vf, au, av, aw) = (g("cell"), g("vf"), g("af_u"), g("af_v"), g("af_w"));
    let (tu, tv, tw) = (g("tu"), g("tv"), g("tw"));
    assert_eq!((cm.nx, cm.ny, cm.nz), (96, 96, 50));
    for (n, a) in [("vf", vf), ("af_u", au), ("af_v", av), ("af_w", aw)] {
        assert_eq!(a.len(), n3, "{n}");
        assert!(a.iter().all(|&x| (0.0..=1.0).contains(&x)), "{n} outside [0, 1]");
    }
    let (mut n_cut, mut n_air, mut n_full) = (0usize, 0usize, 0usize);
    for k in 1..nz - 1 {
        for j in 1..ny - 1 {
            for i in 1..nx - 1 {
                let q = (k * nyx) + j * nx + i;
                assert_eq!(
                    cell[q] == 1.0,
                    vf[q] >= VF_MIN,
                    "cell/vf at (k={k}, j={j}, i={i}): cell {} vf {}",
                    cell[q],
                    vf[q]
                );
                if cell[q] == 1.0 {
                    n_air += 1;
                }
                if vf[q] == 1.0 {
                    n_full += 1;
                    for f in [au[q], au[q + 1], av[q], av[q + nx], aw[q], aw[q + nyx]] {
                        assert_eq!(f, 1.0, "vf = 1, face {f} at (k={k}, j={j}, i={i})");
                    }
                } else if vf[q] >= VF_MIN {
                    n_cut += 1;
                }
            }
        }
    }
    for q in 0..n3 {
        for (t, a, n) in [(tu, au, "u"), (tv, av, "v"), (tw, aw, "w")] {
            if t[q] == 1.0 {
                assert!(a[q] >= 1e-3, "face {n} type 1 with af {} at {q}", a[q]);
            }
        }
    }
    eprintln!("ongudai 400 m: air cells {n_air}, full {n_full}, cut {n_cut}");
    assert!(n_cut > 1000, "a slope must produce cut cells");
}

// ---------------------------------------------------------------- (г) ключ кеша

fn temp_dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "dp-air-{tag}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn cache_key_format_2_rejects_format_1() {
    let cfg = configs_with(|v| {
        v["air"]["deterministic"] = json!(true);
        v["air"]["domain_l_m"] = json!(7200.0);
        v["air"]["threads"] = json!(4);
        v["air"]["tol_scale"] = json!(5.0);
        v["air_model"]["edge_blend_cells"] = json!(1.0);
    });
    let dir = temp_dir("cut-cache");
    let mut pl = flat_place().header().clone();
    pl.model_hash = "model-1".into();
    let n = pl.cells();
    let pl = Place::new(pl, vec![0.0; n], vec![0; n], vec![1; n], vec![0.5; n]).unwrap();
    let mut m = Formula::new().with_faults(Faults {
        coarse: false,
        fail_pass: None,
        no_phase: false,
        no_windows: true,
    });
    m.configure(&cfg, 1).unwrap();
    m.set_cache_dir(dir.to_str().unwrap()).unwrap();
    m.set_conditions(&cond("medium")).unwrap();
    m.load_place(pl).unwrap();
    let t = Instant::now();
    loop {
        match m.status().state {
            State::Ready => break,
            State::Failed => panic!("Failed: {}", m.status().reason),
            _ => {}
        }
        assert!(t.elapsed().as_secs() < 600, "no Ready");
        std::thread::sleep(Duration::from_millis(5));
    }
    let file = loop {
        let f = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.path()).find(|p| {
            p.extension().is_some_and(|x| x == "dpac")
        });
        if let Some(f) = f {
            break f;
        }
        assert!(t.elapsed().as_secs() < 600, "no cache file");
        std::thread::sleep(Duration::from_millis(10));
    };
    // заголовок записи: ключ с format 2
    let raw = std::fs::read(&file).unwrap();
    let hl = u64::from_le_bytes(raw[8..16].try_into().unwrap()) as usize;
    let head: Value = serde_json::from_slice(&raw[16..16 + hl]).unwrap();
    let key2 = head["key"].clone();
    let mh = head["model_hash"].as_str().unwrap().to_string();
    assert_eq!(key2["format"], json!(2), "cache key format");
    let cache = FieldCache::new(&dir);
    assert!(cache.get(&key2, &mh).is_ok(), "own key hits");
    // запись, сохранённая под ключом format 1 (тот же файл), отвергается и удаляется
    let mut key1 = key2.clone();
    key1["format"] = json!(1);
    std::fs::copy(&file, cache.path_of(&key1)).unwrap();
    match cache.get(&key1, &mh) {
        Err(Miss::Rejected(why)) => eprintln!("format 1 rejected: {why}"),
        other => panic!("format 1 must be rejected, got {:?}", other.map(|_| "hit")),
    }
    assert!(!cache.path_of(&key1).exists(), "rejected entry is removed");
}

// ---------------------------------------------------------------- (в) загрузка Онгудая

/// Загрузка Онгудая с окнами 100/50 м: оба решения области сошлись, окна посчитаны, NaN нет.
/// Печатает итерации и время (отчёт PT-9).
#[test]
#[ignore = "Онгудай, release: cargo test --release -p dp-air --test cut_game -- --include-ignored --nocapture"]
fn ongudai_load_with_windows_converges() {
    let cfg = configs_with(|v| {
        v["air"]["deterministic"] = json!(true);
        v["air"]["tol_scale"] = json!(5.0);
    });
    let tol = 1e-6 * 5.0;
    let pl = place("ongudai");
    let st = pl.header().start_sites[0].clone();
    let focus = Focus {
        pos: [st.x as f32, st.h_msl as f32 + 10.0, st.z as f32],
        weight: 1.0,
    };
    let pts: Vec<[f32; 3]> = (-2..=2)
        .flat_map(|i| {
            (-2..=2).map(move |j| [st.x as f32 + 200.0 * i as f32, st.h_msl as f32 + 30.0, st.z as f32 + 200.0 * j as f32])
        })
        .collect();
    let t0 = Instant::now();
    let mut m = Formula::new();
    m.configure(&cfg, 1).unwrap();
    m.set_conditions(&cond("strong")).unwrap();
    m.set_focuses(&[focus]).unwrap();
    m.load_place(pl).unwrap();
    loop {
        match m.status().state {
            State::Ready => break,
            State::Failed => panic!("Failed: {}", m.status().reason),
            _ => {}
        }
        assert!(t0.elapsed().as_secs() < 1800, "no Ready");
        std::thread::sleep(Duration::from_millis(20));
    }
    let wall = t0.elapsed().as_secs_f64();
    let r = m.report().unwrap();
    eprintln!("ongudai load with windows: {wall:.1} s (wall_s {:.1})", r.wall_s);
    for (i, p) in r.passes.iter().enumerate() {
        eprintln!(
            "  pass {}: coarse {:?} iters {:?} stop {:?} div_rms {:?} secs {:?} phase_s {:.2} win_s {:.2} notes {:?}",
            i + 1,
            p.coarse_iters,
            p.iters,
            p.stop,
            p.div_rms,
            p.secs,
            p.phase_s,
            p.win_s,
            p.notes
        );
    }
    for w in &r.windows {
        eprintln!(
            "  window {} m: iters {:?} stop {:?} div_rms {:?} corr {:?} secs {:?}",
            w.dx, w.iters, w.stop, w.div_rms, w.corr, w.secs
        );
    }
    assert!(r.windows_error.is_none(), "{:?}", r.windows_error);
    for p in &r.passes {
        assert!(p.stop.iter().all(|s| *s == Stop::Converged), "stop {:?}", p.stop);
        assert!(p.div_rms.iter().all(|&d| d <= tol), "div_rms {:?} > {tol}", p.div_rms);
    }
    assert_eq!(r.windows.len(), 2, "windows 100 and 50 m");
    assert_eq!(r.windows.iter().map(|w| w.dx).collect::<Vec<_>>(), [100.0, 50.0]);
    for w in &r.windows {
        assert!(w.div_rms.iter().all(|d| d.is_finite() && *d <= tol), "window div_rms {:?}", w.div_rms);
    }
    let mut out = vec![[0.0f32; 4]; pts.len()];
    m.sample_many(&pts, dp_air::SampleMode::Mean, &mut out);
    assert!(out.iter().flatten().all(|v| v.is_finite()), "NaN/inf in the field");
    assert!(out.iter().flatten().any(|v| *v != 0.0));
}
