//! RW-12v: `Formula` отдаёт опросы W4 v6 из `Terms` (место, поле, облака, слоты, ключ места, фон)
//! вместо заглушек. Синтетика (`tests/fixtures/wind/places/synthetic`) с малой областью поля в
//! детерминированном режиме и Онгудай с прогнозом случая
//! `ongudai_day_1`.
#![allow(clippy::needless_range_loop)]
use dp_air::field::runtime::ground_height;
use dp_air::fixtures::{read_case, read_place};
use dp_air::terms::{self, Terms};
use dp_air::{
    AirModel, Cloud, Code, Conditions, Configs, Core, Crest, Focus, Formula, ObjRecord, Place,
    SampleMode, State,
};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

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
            out.push((name, std::fs::read_to_string(&p).unwrap()));
        }
    }
}

/// Конфиги игры; `det` - детерминированный режим и малая область поля (проверки -O0).
fn configs(det: bool) -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere.json" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = json!(det);
            if det {
                v["air"]["domain_l_m"] = json!(7200.0);
                v["air"]["threads"] = json!(4);
                v["air"]["tol_scale"] = json!(5.0);
                v["air_model"]["edge_blend_cells"] = json!(1.0);
                v["air_model"]["window_levels_m"] = json!([]);
                v["thermal"]["generation_radius_m"] = json!(8000.0);
            }
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

fn place(name: &str) -> Place {
    read_place(&repo().join(format!("tests/fixtures/wind/places/{name}.json"))).unwrap()
}

fn preset(name: &str) -> Conditions {
    Conditions::from_json(&format!(
        r#"{{"preset":"{name}","start_hour":12,"speed":1,"blend_s":null,"rebuild":false,"inflow_mode":"inflow"}}"#
    ))
    .unwrap()
}

fn ongudai_day() -> (Conditions, Vec<Focus>) {
    let c = read_case(&repo().join("tests/fixtures/wind/cases/ongudai_day_1.json")).unwrap();
    (c.conditions, c.focuses)
}

fn wait_ready(m: &Formula) {
    let t0 = Instant::now();
    loop {
        match m.status().state {
            State::Ready => return,
            State::Failed => panic!("Failed: {}", m.status().reason),
            _ => {}
        }
        assert!(t0.elapsed() < Duration::from_secs(600), "no Ready");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// Синтетика с полем: детерминированный режим, фокус на склоне, `advance_to` до `t` секунд.
fn synth_with_field(name: &str, t: f64) -> Formula {
    let pl = place("synthetic");
    let mut m = Formula::new();
    m.configure(&configs(true), 1).unwrap();
    m.set_conditions(&preset(name)).unwrap();
    m.set_focuses(&[Focus {
        pos: [1000.0, ground_height(&pl, 1000.0, 1000.0) + 10.0, 1000.0],
        weight: 1.0,
    }])
    .unwrap();
    m.load_place(pl).unwrap();
    wait_ready(&m);
    m.poll();
    let mut at = 0.0;
    while at < t {
        at = (at + 30.0).min(t);
        m.advance_to(at).unwrap();
    }
    m
}

/// Онгудай: прогноз `ongudai_day_1`, термики по клеткам, погода по часу.
fn ongudai_ready(t: f64) -> Formula {
    let (c, f) = ongudai_day();
    let mut m = Formula::new();
    m.configure(&configs(true), 7).unwrap();
    m.set_conditions(&c).unwrap();
    m.set_focuses(&f).unwrap();
    m.load_place(read_place(&repo().join("tests/fixtures/wind/places/ongudai.json")).unwrap())
        .unwrap();
    wait_ready(&m);
    let mut at = 0.0;
    while at < t {
        at = (at + 30.0).min(t);
        m.advance_to(at).unwrap();
    }
    m
}

fn probes(pl: &Place) -> Vec<[f32; 3]> {
    let mut v = Vec::new();
    for i in -2..=2 {
        for j in -2..=2 {
            let (x, z) = (300.0 * i as f32 + 1000.0, 300.0 * j as f32 + 1000.0);
            let g = ground_height(pl, x, z);
            for a in [30.0, 150.0, 400.0, 900.0] {
                v.push([x, g + a, z]);
            }
        }
    }
    v
}

fn terms_of(m: &Formula) -> std::sync::Arc<Terms> {
    m.terms_snapshot()
}

// ---------------------------------------------------------------- нет места / не Ready

#[test]
fn no_place_answers_are_empty() {
    let m = Formula::new();
    let (mut cores, mut clouds, mut objs, mut crests) = (
        vec![Core::default(); 2],
        vec![Cloud::default(); 2],
        vec![ObjRecord::default(); 2],
        vec![Crest::default(); 2],
    );
    m.cores([0.0; 3], 1e4, &mut cores);
    m.clouds([0.0; 3], 1e4, &mut clouds);
    m.cloud_objects([0.0; 3], -1.0, 0.0, &mut objs);
    m.wave_crests([0.0; 2], 1e4, 0.0, 50.0, &mut crests);
    assert!(cores.is_empty() && clouds.is_empty() && objs.is_empty() && crests.is_empty());
    assert!(m.cloud_raster().is_none());
    let mut d = [1.0f32; 3];
    m.cloud_density_many(&[[0.0; 3]; 3], &mut d);
    assert_eq!(d, [0.0; 3]);
    let mut g = [1.0f32; 2];
    m.surface_gust_many(&[[0.0; 2]; 2], &[0.0; 2], &mut g);
    assert_eq!(g, [0.0; 2]);
    let mut b = [[1.0f32; 2]; 2];
    m.background_wind(&[100.0, 200.0], &mut b);
    assert_eq!(b, [[0.0; 2]; 2]);
    assert_eq!(m.wave_info(), [0.0; 2]);
    assert_eq!(m.weather_json(), "{}");
    assert_eq!(m.sun_state(), [0.0; 4]);
    assert_eq!(m.cloudbase_msl(), 0.0);
    assert_eq!(m.weather_version(), (0, 0));
}

#[test]
fn forecast_needs_climate_cell() {
    // у синтетики климат задан, а сырой ячейки (W5 v8) нет: прогноз невозможен
    let (c, _) = ongudai_day();
    let mut m = Formula::new();
    m.configure(&configs(true), 1).unwrap();
    m.load_place(place("synthetic")).unwrap();
    assert_eq!(m.set_conditions(&c).unwrap_err().code, Code::BadInput);
    // эталон-пресет ячейки не требует
    m.set_conditions(&preset("medium")).unwrap();
    // обратный порядок: условия раньше места
    let mut m = Formula::new();
    m.configure(&configs(true), 1).unwrap();
    m.set_conditions(&c).unwrap();
    assert_eq!(
        m.load_place(place("synthetic")).unwrap_err().code,
        Code::BadInput
    );
}

// ---------------------------------------------------------------- слагаемые вместо заглушек

#[test]
fn queries_equal_terms_functions() {
    let m = synth_with_field("strong", 1500.0);
    let t = terms_of(&m);
    let now = 1500.0;
    // ядра подъёма: непусты и равны прямому вызову
    let (mut a, mut b) = (Vec::new(), Vec::new());
    m.cores([1000.0, 0.0, 1000.0], 6000.0, &mut a);
    t.thermal_cores([1000.0, 0.0, 1000.0], 6000.0, now, &mut b);
    assert!(!a.is_empty(), "no thermals in a strong day");
    assert_eq!(a, b);
    // облака поля и Cb
    let (mut ca, mut cb) = (Vec::new(), Vec::new());
    m.clouds([1000.0, 0.0, 1000.0], 8000.0, &mut ca);
    terms::clouds::clouds(&t, [1000.0, 0.0, 1000.0], 8000.0, now, &mut cb);
    assert_eq!(ca, cb);
    // растр облаков - тот же снимок
    match (m.cloud_raster(), terms::clouds::cloud_raster(&t)) {
        (Some(x), Some(y)) => assert!(std::sync::Arc::ptr_eq(&x, &y)),
        (None, None) => {}
        _ => panic!("raster differs"),
    }
    // плотность
    let pl = place("synthetic");
    let pts = probes(&pl);
    let (mut da, mut db) = (vec![0.0; pts.len()], vec![0.0; pts.len()]);
    m.cloud_density_many(&pts, &mut da);
    terms::clouds::cloud_density_many(&t, &pts, &mut db);
    assert_eq!(da, db);
    // объекты-облака
    let (mut oa, mut ob) = (Vec::new(), Vec::new());
    m.cloud_objects([1000.0, 0.0, 1000.0], -1.0, now, &mut oa);
    terms::objects::cloud_objects_into(&t, [1000.0, 0.0, 1000.0], -1.0, now, &mut ob);
    assert_eq!(oa, ob);
    // облачность в кромке и фоновый ветер: кромка собрана, фон растёт с высотой
    assert!(m.cloudbase_msl() > 0.0);
    assert!(
        (m.cloudbase_msl() - t.cloudbase_msl()).abs() < 1.0,
        "analytic and thermal cloud base differ"
    );
}

#[test]
fn full_sample_equals_decompose_total() {
    let m = synth_with_field("strong", 1500.0);
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut full = vec![[0.0f32; 4]; pts.len()];
    m.sample_many(&pts, SampleMode::Full, &mut full);
    let mut thermal = 0.0f32;
    for (p, f) in pts.iter().zip(&full) {
        let d = m.decompose(*p);
        for k in 0..4 {
            assert!((d.total[k] - f[k]).abs() <= 1e-4, "total {k} at {p:?}");
        }
        let k = d.names.iter().position(|n| n == "thermal").unwrap();
        thermal = thermal.max(d.vel[k][1].abs());
    }
    assert!(thermal > 0.0, "thermals do not contribute");
}

#[test]
fn surface_gust_equals_terms_and_lengths_by_min() {
    let m = synth_with_field("strong", 600.0);
    let t = terms_of(&m);
    let xz: Vec<[f32; 2]> = (0..40)
        .map(|i| [i as f32 * 37.0, 500.0 - i as f32 * 11.0])
        .collect();
    let ts: Vec<f64> = (0..40).map(|i| 100.0 + i as f64 * 0.5).collect();
    let (mut a, mut b) = (vec![0.0f32; 40], vec![0.0f32; 40]);
    m.surface_gust_many(&xz, &ts, &mut a);
    terms::surface_gust::surface_gust_many(&t, &xz, &ts, &mut b);
    assert_eq!(a, b);
    assert!(a.iter().any(|v| *v > 1.0), "gust is zero at strong wind");
    // длина - по минимуму трёх; остальное в out не трогается
    let mut c = vec![-1.0f32; 10];
    m.surface_gust_many(&xz[..5], &ts, &mut c);
    assert!(c[..5].iter().all(|v| *v >= 0.0) && c[5..].iter().all(|v| *v == -1.0));
}

#[test]
fn cloud_objects_time_is_clamped_to_history_window() {
    let m = synth_with_field("strong", 1500.0);
    let at = |t: f64| {
        let mut o = Vec::new();
        m.cloud_objects([1000.0, 0.0, 1000.0], -1.0, t, &mut o);
        o
    };
    let now = at(1500.0);
    assert_eq!(at(1e9), now);
    assert_eq!(at(f64::NAN), now);
    assert_eq!(at(-1e9), at(1500.0 - 60.0));
}

// ---------------------------------------------------------------- погода, солнце, версии

#[test]
fn weather_sun_and_version_follow_the_day() {
    let mut m = ongudai_ready(30.0);
    let w: Value = serde_json::from_str(&m.weather_json()).unwrap();
    assert!(
        w.get("wind_speed_kmh").is_some() && w.get("_derived").is_some(),
        "weather is not derived: {w}"
    );
    let s = m.sun_state();
    let l = (s[0] * s[0] + s[1] * s[1] + s[2] * s[2]).sqrt();
    assert!(
        (l - 1.0).abs() < 1e-3 && (0.0..=1.0).contains(&s[3]),
        "sun {s:?}"
    );
    // погода, не изменившаяся заметно, версию не поднимает (шаг 0,1 с атмосферы, 100 шагов)
    let v0 = m.weather_version();
    let mut t = 30.0;
    for _ in 0..100 {
        t += 0.1;
        m.advance_to(t).unwrap();
    }
    let v1 = m.weather_version();
    assert!(v1.0 <= v0.0 + 1 && v1.1 == v0.1, "{v0:?} -> {v1:?}");
    // перестройка растит обе
    let mut c = ongudai_day().0;
    c.rebuild = true;
    m.set_conditions(&c).unwrap();
    let v2 = m.weather_version();
    assert_eq!((v2.0, v2.1), (v1.0 + 1, v1.1 + 1));
    // опрос без изменений - тот же номер
    assert_eq!(m.weather_version(), v2);
}

#[test]
fn background_wind_follows_profile_and_direction() {
    let m = ongudai_ready(60.0);
    let t = terms_of(&m);
    let pl = read_place(&repo().join("tests/fixtures/wind/places/ongudai.json")).unwrap();
    let cb = f64::from(m.cloudbase_msl());
    assert!(cb > 0.0);
    let agl = t.weather.f64_or("cloudbase_agl_m", 1500.0);
    let gr = cb - agl;
    let hs = [
        gr as f32 - 50.0,
        gr as f32 + 10.0,
        gr as f32 + 500.0,
        f32::NAN,
    ];
    let mut out = [[0.0f32; 2]; 4];
    m.background_wind(&hs, &mut out);
    let mut direct = [[0.0f32; 2]; 4];
    terms::analytic::background_wind(&t, &pl, &hs, &mut direct);
    assert_eq!(out, direct);
    let dir = t.wind.dir();
    for (o, h) in out.iter().zip(&hs).take(3) {
        let u = t
            .wind
            .speed_at_pos((f64::from(*h) - gr).max(0.0), f64::from(*h));
        let sp = f64::from(o[0]).hypot(f64::from(o[1]));
        assert!(
            (sp - u).abs() < 1e-2 * u.max(1.0),
            "speed {sp} vs {u} at {h}"
        );
        assert!(f64::from(o[0]) * dir[0] + f64::from(o[1]) * dir[1] > 0.0);
    }
    assert_eq!(out[3], [0.0; 2]);
}

// ---------------------------------------------------------------- ключ места, поле

#[test]
fn reload_other_place_does_not_reuse_wave_cache() {
    let (c, f) = (preset("wave"), vec![]);
    let run = |names: &[&str]| {
        let mut m = Formula::new();
        m.configure(&configs(true), 3).unwrap();
        m.set_conditions(&c).unwrap();
        m.set_focuses(&f).unwrap();
        let mut last = Vec::new();
        for n in names {
            m.unload_place();
            m.load_place(place(n)).unwrap();
            m.advance_to(1.0).unwrap();
            m.wave_crests([0.0; 2], 6000.0, 0.0, 100.0, &mut last);
        }
        (last, m.wave_info())
    };
    let direct = run(&["training_island"]);
    let after = run(&["synthetic", "training_island"]);
    assert_eq!(direct, after);
    assert!(direct.1[0] == 1.0 && direct.1[1] > 100.0, "{:?}", direct.1);
}

#[test]
fn unload_clears_everything_and_reload_restores() {
    let mut m = synth_with_field("strong", 900.0);
    let mut cores = Vec::new();
    m.cores([1000.0, 0.0, 1000.0], 6000.0, &mut cores);
    assert!(!cores.is_empty());
    m.unload_place();
    m.cores([1000.0, 0.0, 1000.0], 6000.0, &mut cores);
    assert!(cores.is_empty() && m.cloud_raster().is_none());
    assert_eq!(m.weather_json(), "{}");
    assert_eq!(m.status().state, State::Empty);
}

#[test]
fn start_at_is_deterministic_for_thermals() {
    let mut a = synth_with_field("strong", 0.0);
    let mut b = synth_with_field("strong", 0.0);
    a.start_at(1200.0).unwrap();
    b.advance_to(600.0).unwrap();
    b.start_at(1200.0).unwrap();
    for m in [&mut a, &mut b] {
        wait_ready(m);
        m.advance_to(1201.0).unwrap();
        wait_ready(m);
    }
    let (mut ca, mut cb) = (Vec::new(), Vec::new());
    a.cores([1000.0, 0.0, 1000.0], 6000.0, &mut ca);
    b.cores([1000.0, 0.0, 1000.0], 6000.0, &mut cb);
    assert!(!ca.is_empty());
    assert_eq!(ca, cb);
}

#[test]
fn background_cloud_step_does_not_block_advance() {
    // недетерминированный режим: облака шагают в фоне, `advance_to` не ждёт
    let pl = place("synthetic");
    let mut m = Formula::new();
    m.configure(&configs(false), 1).unwrap();
    m.set_conditions(&preset("strong")).unwrap();
    m.set_focuses(&[Focus {
        pos: [1000.0, ground_height(&pl, 1000.0, 1000.0) + 10.0, 1000.0],
        weight: 1.0,
    }])
    .unwrap();
    m.load_place(pl).unwrap();
    m.start_at(1200.0).unwrap();
    let mut t = 1200.0;
    let mut worst = Duration::ZERO;
    for _ in 0..400 {
        t += 1.0 / 30.0;
        let t0 = Instant::now();
        m.advance_to(t).unwrap();
        worst = worst.max(t0.elapsed());
        std::thread::sleep(Duration::from_millis(2));
    }
    assert!(m.wait_terms(Duration::from_secs(60)));
    m.advance_to(t + 0.2).unwrap();
    assert!(terms_of(&m).clouds.physics().version > 0);
    eprintln!("worst advance_to: {worst:?}");
}

/// RW-P2: отладочные растры W7 после расчёта поля - поток тепла (F7) и главная фаза (F4): имена,
/// размеры `nx·ny = len(data)`, конечные значения, индексы фаз; без поля растров нет.
#[test]
fn debug_rasters_follow_the_field() {
    let m = synth_with_field("strong", 60.0);
    let names = m.debug_raster_names();
    assert!(names.iter().any(|n| n == "heat_flux"), "{names:?}");
    assert!(names.iter().any(|n| n == "phase_main"), "{names:?}");
    for n in ["heat_flux", "phase_main"] {
        let r = m
            .debug_raster(n)
            .unwrap_or_else(|| panic!("{n}: нет растра"));
        let (_, data) = r.layers.iter().find(|(l, _)| l == "data").unwrap();
        assert!(r.nx > 1 && r.ny > 1 && r.dx > 0.0 && r.version > 0, "{n}");
        assert_eq!(data.len(), (r.nx * r.ny) as usize, "{n}: nx·ny");
        assert!(data.iter().all(|v| v.is_finite()), "{n}: конечны");
        assert!(r.x0.is_finite() && r.z0.is_finite(), "{n}: начало");
        if n == "phase_main" {
            assert!(
                data.iter()
                    .all(|&v| (0.0..7.0).contains(&v) && v.fract() == 0.0)
            );
        } else {
            assert!(
                data.iter().any(|&v| v > 0.0),
                "тепло над землёй при сильном дне"
            );
        }
    }
    assert!(m.debug_raster("нет такого").is_none());
}
