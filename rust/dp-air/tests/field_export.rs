//! RW-7a: режим поля и выдача поля фасаду (W4 v5, W3 v4) — запечённое поле острова, без Пикара.
//!
//! Снимок (`field_export`) разбирается `parse_baked` обратно бит в бит; опрос набора по нему
//! совпадает с опросом `Formula`; `set_field_enabled` снимает и возвращает поле, не трогая `state`.
use dp_air::field::baked::parse_baked;
use dp_air::field::field_set::FieldSet;
use dp_air::field::runtime::{Faults, RtCfg, ground_height};
use dp_air::{AirModel, Calm, Conditions, Configs, Focus, Formula, Place, SampleMode, State};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const NO_WIN: Faults = Faults {
    coarse: false,
    fail_pass: None,
    no_phase: false,
    no_windows: true,
};

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

/// Конфиги игры в детерминированном режиме, малая область.
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
    Place::new(h, vec![100.0; n], vec![0; n], vec![1; n], vec![0.5; n]).unwrap()
}

fn landing_cond() -> Conditions {
    Conditions::from_json(
        r#"{"forecast":{"temperature_c":22,"wind_speed_kmh":3.6,"wind_from_deg":270,"sky":"clear"},
"quantum_h":1,"start_hour":9,"speed":1,"blend_s":null,"rebuild":false}"#,
    )
    .unwrap()
}

fn focus() -> Focus {
    Focus {
        pos: [3510.0, 110.0, -1510.0],
        weight: 1.0,
    }
}

/// Рабочая `Formula` с запечённым полем: место, условия, фокус, поля; ждёт `Ready` с полем.
fn ready_model(windows: bool) -> (Formula, Place) {
    let pl = island_place();
    let mut m = Formula::new();
    if !windows {
        m = m.with_faults(NO_WIN);
    }
    m.configure(&configs(), 1).unwrap();
    m.set_conditions(&landing_cond()).unwrap();
    m.set_focuses(&[focus()]).unwrap();
    m.load_place(pl.clone()).unwrap();
    for (h, b) in island_files() {
        m.add_baked_field(&h, &b).unwrap();
    }
    wait_field(&mut m);
    (m, pl)
}

fn wait_field(m: &mut Formula) {
    let t0 = Instant::now();
    loop {
        m.poll();
        if m.status().state == State::Ready && m.level_count() > 0 {
            return;
        }
        assert_ne!(m.status().state, State::Failed, "{}", m.status().reason);
        assert!(t0.elapsed() < Duration::from_secs(120), "no field in 120 s");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// 200 точек: окна (шаг 100 м у площадки), область (шаг 1 км) и приземный слой.
fn probes(pl: &Place) -> Vec<[f32; 3]> {
    let mut v = Vec::new();
    for i in -5..5 {
        for j in -5..5 {
            let (x, z) = (3510.0 + 100.0 * i as f32, -1510.0 + 100.0 * j as f32);
            let g = ground_height(pl, x, z);
            v.push([x, g + 2.0, z]);
            v.push([x, g + 120.0, z]);
        }
    }
    for i in -3..3 {
        for j in -3..3 {
            let (x, z) = (3510.0 + 1000.0 * i as f32, -1510.0 + 1000.0 * j as f32);
            let g = ground_height(pl, x, z);
            v.push([x, g + 300.0, z]);
            v.push([x, g + 40.0, z]);
        }
    }
    v.truncate(200);
    assert_eq!(v.len(), 200);
    v
}

fn sample(m: &dyn AirModel, pts: &[[f32; 3]]) -> Vec<[f32; 4]> {
    let mut out = vec![[9.0f32; 4]; pts.len()];
    m.sample_many(pts, SampleMode::Mean, &mut out);
    out
}

fn bits(v: &[[f32; 4]]) -> Vec<u32> {
    v.iter().flatten().map(|x| x.to_bits()).collect()
}

/// (1) Снимок после `Ready` на запечённом поле разбирается обратно, опрос по нему = `Formula`.
#[test]
fn export_parses_back_and_samples_bit_for_bit() {
    let (m, pl) = ready_model(true);
    let pts = probes(&pl);
    let v = m.field_version();
    assert!(v > 0);
    let e = m.field_export();
    assert_eq!(e.version, v);
    assert!(!e.header_json.is_empty() && !e.data.is_empty());
    let b = parse_baked(&e.header_json, &e.data).unwrap();
    assert_eq!(b.levels.len(), 3, "окна 50/100 м и область");
    let rt = RtCfg::from_configs(&configs()).unwrap();
    let mut fs = FieldSet::new(rt.limits, rt.edge_blend_cells);
    fs.set_field(b.levels, 0.0);
    let want = sample(&m, &pts);
    assert!(want.iter().flatten().any(|x| *x != 0.0));
    let got: Vec<[f32; 4]> = pts
        .iter()
        .map(|p| {
            let s = fs.sample(*p, ground_height(&pl, p[0], p[2]));
            let f = |x: f64| x as f32;
            [f(s.v[0]), f(s.v[1]), f(s.v[2]), 0.0]
        })
        .collect();
    assert_eq!(bits(&got), bits(&want));
}

/// (2) Заголовок несёт номер подачи, `blend_s = 0` для первой подачи и `blend_t0`.
#[test]
fn header_carries_version_and_blend() {
    let (m, _) = ready_model(false);
    let e = m.field_export();
    let h: Value = serde_json::from_str(&e.header_json).unwrap();
    assert_eq!(h["field_version"].as_u64().unwrap(), e.version);
    assert_eq!(h["blend_s"].as_f64().unwrap(), 0.0);
    assert_eq!(e.blend_s, 0.0);
    assert!(h["blend_t0"].as_f64().is_some());
    assert_eq!(h["blend_t0"].as_f64().unwrap(), e.blend_t0);
    assert_eq!(h["format"], parse_ok_format(&e));
    // без новой подачи номер и снимок те же
    assert_eq!(m.field_export(), e);
}

fn parse_ok_format(e: &dp_air::FieldExport) -> Value {
    parse_baked(&e.header_json, &e.data).unwrap();
    let h: Value = serde_json::from_str(&e.header_json).unwrap();
    h["format"].clone()
}

/// (3) `set_field_enabled(false)`: поля нет, номер растёт, снимок пуст, `state` всё время `Ready`;
/// `true` — то же запечённое поле возвращается, подача сразу.
#[test]
fn field_off_and_on_again() {
    let (mut m, pl) = ready_model(false);
    let pts = probes(&pl);
    let before = sample(&m, &pts);
    let v0 = m.field_version();
    let first = m.field_export();
    assert_eq!(m.set_field_enabled(true).is_ok(), true, "повтор — Ok");
    assert_eq!(m.field_version(), v0);

    m.set_field_enabled(false).unwrap();
    assert_eq!(m.status().state, State::Ready);
    assert!(m.field_version() > v0);
    assert!(
        sample(&m, &pts).iter().flatten().all(|x| *x == 0.0),
        "поле снято сразу"
    );
    let off = m.field_export();
    assert_eq!(off.version, m.field_version());
    assert!(off.header_json.is_empty() && off.data.is_empty());

    m.set_field_enabled(true).unwrap();
    assert_eq!(m.status().state, State::Ready);
    let t0 = Instant::now();
    while m.field_export().header_json.is_empty() {
        m.poll();
        assert_eq!(m.status().state, State::Ready, "state не меняется");
        assert!(t0.elapsed() < Duration::from_secs(120));
        std::thread::sleep(Duration::from_millis(2));
    }
    let back = m.field_export();
    assert!(back.version > off.version);
    assert_eq!(back.blend_s, 0.0, "первое поле — сразу");
    let a = parse_baked(&first.header_json, &first.data).unwrap();
    let b = parse_baked(&back.header_json, &back.data).unwrap();
    assert_eq!(a.levels.len(), b.levels.len());
    assert_eq!(a.levels[0].raw_u(), b.levels[0].raw_u());
    assert_eq!(sample(&m, &pts).len(), before.len());
    assert!(sample(&m, &pts).iter().flatten().any(|x| *x != 0.0));
}

/// (3б) Выключение до `load_place` запоминается: поля нет, `Ready` сразу; включение — поле.
#[test]
fn field_off_before_load_is_remembered() {
    let pl = island_place();
    let mut m = Formula::new().with_faults(NO_WIN);
    m.configure(&configs(), 1).unwrap();
    m.set_conditions(&landing_cond()).unwrap();
    m.set_focuses(&[focus()]).unwrap();
    m.set_field_enabled(false).unwrap();
    m.load_place(pl.clone()).unwrap();
    for (h, b) in island_files() {
        m.add_baked_field(&h, &b).unwrap();
    }
    m.advance_to(1.0).unwrap();
    assert_eq!(m.status().state, State::Ready);
    assert!(m.field_export().header_json.is_empty());
    assert!(sample(&m, &probes(&pl)).iter().flatten().all(|x| *x == 0.0));
    m.set_field_enabled(true).unwrap();
    wait_field(&mut m);
    assert!(!m.field_export().header_json.is_empty());
}

/// (4) `unload_place` — снимок пуст, номер растёт.
#[test]
fn unload_place_empties_the_export() {
    let (mut m, _) = ready_model(false);
    let v = m.field_version();
    m.unload_place();
    assert!(m.field_version() > v);
    let e = m.field_export();
    assert_eq!(e.version, m.field_version());
    assert!(e.header_json.is_empty() && e.data.is_empty());
}

/// (5) `Calm` — пустой снимок, `set_field_enabled` — `Ok`.
#[test]
fn calm_has_empty_export() {
    let mut c = Calm::new();
    c.set_field_enabled(false).unwrap();
    c.set_field_enabled(true).unwrap();
    assert_eq!(c.field_version(), 0);
    let e = c.field_export();
    assert_eq!(e, dp_air::FieldExport::default());
}

/// (6) Пока поле выключено, смена условий и время расчётов не запускают: задачи нет, `state`
/// `Ready`, поле пусто, номер подачи не растёт.
#[test]
fn no_recompute_while_field_is_off() {
    let (mut m, pl) = ready_model(false);
    m.set_field_enabled(false).unwrap();
    let v = m.field_version();
    let other = Conditions::from_json(
        r#"{"forecast":{"temperature_c":30,"wind_speed_kmh":18,"wind_from_deg":90,"sky":"clear"},
"quantum_h":1,"start_hour":9,"speed":1,"blend_s":null,"rebuild":true}"#,
    )
    .unwrap();
    m.set_conditions(&other).unwrap();
    for t in [1.0, 600.0, 4000.0] {
        m.advance_to(t).unwrap();
        assert!(m.wait_job(Duration::ZERO), "расчёта нет");
        assert_eq!(m.status().state, State::Ready);
    }
    m.start_at(5000.0).unwrap();
    assert!(m.wait_job(Duration::ZERO));
    assert_eq!(m.status().state, State::Ready);
    assert_eq!(m.field_version(), v);
    assert!(sample(&m, &probes(&pl)).iter().flatten().all(|x| *x == 0.0));
}
