//! RW-25: термики в игре без ожидания. Игра: условия (прогноз, `rebuild:false`) до `load_place`, дальше
//! только `advance_to`; ядра должны быть сразу после готовности поля, как при `rebuild:true`.
mod common;

use dp_air::{AirModel, Conditions, Configs, Core, Focus, Formula, Place, PlaceHeader, State};
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
            out.push((
                name.trim_end_matches(".json").to_string(),
                std::fs::read_to_string(&p).unwrap(),
            ));
        }
    }
}

/// Конфиги игры; `det` - детерминированный режим и малая область поля (проверки -O0).
fn configs(det: bool) -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = json!(det);
            v["air"]["domain_l_m"] = json!(7200.0);
            v["air"]["threads"] = json!(4);
            v["air"]["tol_scale"] = json!(5.0);
            v["air_model"]["edge_blend_cells"] = json!(1.0);
            v["air_model"]["window_levels_m"] = json!([]);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

fn hills(x: f64, z: f64) -> f64 {
    1300.0 + 150.0 * (x / 700.0).sin() * (z / 900.0).cos()
}

/// Как `AirPlaceData.from_functions` стенда: квадрат 10 км с шагом `sp`, луг, влажность 1.
fn rig_place(sp: f64) -> Place {
    let half = 5000.0f64;
    let n = (2.0 * half / sp).round() as usize + 1;
    let h = format!(
        r#"{{"version":1,"loc":{{"id":"rig","center_lat":51.5,"center_lon":86.5,"utc_offset_h":6.0,
        "month":7,"day":15}},
        "grid":{{"origin_x":{},"origin_z":{},"spacing":{sp},"width":{n},"height":{n}}},
        "surface_classes":{{"none":0,"forest":1,"grass":2,"crop":3,"shrub":4,"bare":5,"water":6,"built":7,"snow":8}},
        "start_sites":[{{"x":0.0,"z":0.0,"h_msl":1400.0}}]}}"#,
        -half, -half
    );
    let header = PlaceHeader::from_json(&h).unwrap();
    let mut hs = Vec::with_capacity(n * n);
    for j in 0..n {
        for i in 0..n {
            hs.push(hills(-half + sp * i as f64, -half + sp * j as f64) as f32);
        }
    }
    Place::new(header, hs, vec![0; n * n], vec![2; n * n], vec![1.0; n * n]).unwrap()
}

const FORECAST: &str = r#"{"forecast":{"temperature_c":26,"wind_speed_kmh":10.8,"wind_from_deg":225,"sky":"clear"},
    "start_hour":14,"speed":1,"quantum_h":0.25,"inflow_mode":"inflow","rebuild":REB}"#;

fn cond(reb: bool) -> Conditions {
    Conditions::from_json(&FORECAST.replace("REB", &reb.to_string())).unwrap()
}

fn cores_at(m: &Formula) -> Vec<Core> {
    let mut c = Vec::new();
    m.cores([0.0, 300.0, 0.0], 30000.0, &mut c);
    c
}

fn wait_ready(m: &mut Formula) {
    let t0 = Instant::now();
    while m.status().state == State::Loading {
        assert!(t0.elapsed() < Duration::from_secs(600), "no Ready");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// `first`: условия до `load_place` (пресет по умолчанию или сразу прогноз); затем прогноз с `reb`.
fn run(first_forecast: bool, reb: bool) -> usize {
    let mut m = Formula::new();
    m.configure(&configs(false), 7).unwrap();
    m.set_weather(common::real_weather());
    if first_forecast {
        m.set_conditions(&cond(false)).unwrap();
    } else {
        let c = r#"{"preset":"strong","start_hour":12,"speed":1,"rebuild":false}"#;
        m.set_conditions(&Conditions::from_json(c).unwrap())
            .unwrap();
    }
    m.set_focuses(&[Focus {
        pos: [0.0, 300.0, 0.0],
        weight: 1.0,
    }])
    .unwrap();
    m.set_static_thermals(&[[100.0, 100.0, 3.0, 150.0]], 0)
        .unwrap();
    m.load_place(rig_place(25.0)).unwrap();
    wait_ready(&mut m);
    if !first_forecast {
        m.set_conditions(&cond(reb)).unwrap();
    }
    let mut n = 0;
    let mut t = 0.0;
    for _ in 0..40 {
        // без ожидания: как кадры игры сразу после готовности
        t += 15.0;
        m.advance_to(t).unwrap();
        if t > 150.0 {
            n += cores_at(&m).len();
        }
    }
    n
}

#[test]
fn game_order_no_rebuild_has_cores() {
    let with_rebuild = run(false, true);
    let no_rebuild = run(false, false);
    let before_place = run(true, false);
    assert!(with_rebuild > 0, "rebuild:true: {with_rebuild}");
    assert!(
        no_rebuild > 0,
        "rebuild:false after load_place: {no_rebuild} (rebuild:true {with_rebuild})"
    );
    assert!(
        before_place > 0,
        "forecast before load_place: {before_place}"
    );
}
