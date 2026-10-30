//! RW-15: физика шага не меняется. Эталон снят до правок: `sample_many(Full)` по сетке 15x15 вокруг
//! фокуса и `cores()` после 60 игровых секунд на плоском месте 401² (шаг 25 м, статичные термики,
//! без ветра, детерминированный режим). Сравнение побитно.
//! Перезапись эталона: `RW15_WRITE=1 cargo test --release -p dp-air --test step_cost_same`.
use dp_air::{
    AirModel, Conditions, Configs, Focus, Formula, Place, PlaceHeader, SampleMode, State,
};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

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

fn configs() -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = json!(true);
            v["air"]["tol_scale"] = json!(5.0);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

fn flat_place(n: usize) -> Place {
    let sp = 25.0f64;
    let half = sp * (n - 1) as f64 / 2.0;
    let h = format!(
        r#"{{"version":1,"loc":{{"id":"xc","center_lat":51.5,"center_lon":86.5,"utc_offset_h":6.0,
        "month":7,"day":15,
        "climate":{{"tx_c":24.0,"dtr_k":12.0,"z_cell_m":0.0,"has_hh1":false,"has_hh5":true}},
        "climate_lag":{{"tx_c":22.0,"dtr_k":12.0,"z_cell_m":0.0,"has_hh1":false,"has_hh5":true}}}},
        "grid":{{"origin_x":{},"origin_z":{},"spacing":{sp},"width":{n},"height":{n}}},
        "surface_classes":{{"none":0,"forest":1,"grass":2,"crop":3,"shrub":4,"bare":5,"water":6,"built":7,"snow":8}},
        "start_sites":[]}}"#,
        -half, -half
    );
    let header = PlaceHeader::from_json(&h).unwrap();
    Place::new(
        header,
        vec![500.0; n * n],
        vec![0; n * n],
        vec![2; n * n],
        vec![1.0; n * n],
    )
    .unwrap()
}

fn snapshot() -> Vec<f32> {
    let mut m = Formula::new();
    m.configure(&configs(), 7).unwrap();
    let mut p: Value = serde_json::from_str(
        &std::fs::read_to_string(repo().join("configs/weather/medium.json")).unwrap(),
    )
    .unwrap();
    p["wind_speed_kmh"] = json!(0.0);
    p["thermal_mode"] = json!("static");
    p["static_thermals"] = json!([]);
    let c = format!(
        r#"{{"preset":{p},"start_hour":12,"speed":1,"blend_s":null,"rebuild":false,"inflow_mode":"inflow"}}"#
    );
    m.set_conditions(&Conditions::from_json(&c).unwrap())
        .unwrap();
    m.set_static_thermals(
        &[[300.0, 100.0, 3.0, 100.0], [1500.0, -200.0, 3.0, 100.0]],
        1,
    )
    .unwrap();
    let f = |x: f32| Focus {
        pos: [x, 800.0, 0.0],
        weight: 1.0,
    };
    m.set_focuses(&[f(0.0)]).unwrap();
    m.load_place(flat_place(401)).unwrap();
    while m.status().state == State::Loading {
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    assert_eq!(m.status().state, State::Ready, "{}", m.status().reason);
    m.start_at(0.0).unwrap();
    for i in 1..=3600 {
        let t = f64::from(i) / 60.0;
        m.set_focuses(&[f((12.0 * t) as f32)]).unwrap();
        m.advance_to(t).unwrap();
    }
    let c = 720.0f32;
    let mut pts = Vec::new();
    for j in 0..15 {
        for i in 0..15 {
            pts.push([
                c + (i as f32 - 7.0) * 60.0,
                300.0 + 20.0 * j as f32,
                (j as f32 - 7.0) * 60.0,
            ]);
        }
    }
    let mut out = vec![[0.0f32; 4]; pts.len()];
    m.sample_many(&pts, SampleMode::Full, &mut out);
    let mut v: Vec<f32> = out.iter().flatten().copied().collect();
    let mut cores = Vec::new();
    m.cores([c, 800.0, 0.0], 3000.0, &mut cores);
    v.push(cores.len() as f32);
    for k in &cores {
        v.extend_from_slice(&k.to_array());
    }
    v
}

#[test]
fn step_result_same_as_before() {
    let v = snapshot();
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/data/RW-15/ref.json");
    if std::env::var("RW15_WRITE").is_ok() {
        let bits: Vec<u32> = v.iter().map(|x| x.to_bits()).collect();
        std::fs::write(&path, serde_json::to_string(&bits).unwrap()).unwrap();
        return;
    }
    let bits: Vec<u32> = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(bits.len(), v.len(), "length");
    for (i, (a, b)) in bits.iter().zip(&v).enumerate() {
        assert_eq!(
            *a,
            b.to_bits(),
            "value {i}: {} vs {}",
            f32::from_bits(*a),
            b
        );
    }
}
