//! RW-21: цена первой синхронной сборки термиков (RW-25) на месте ~30 км, порядок игры:
//! прогноз без rebuild -> load_place -> READY -> advance_to кадрами по 1/60 с (фокус стоит).
//! Печатает json: мс первого шага, медиана следующих 59, first_air_builds. Аргументы: `--n=1201 --reps=3`.
//! Место синтетическое (холмы, луг, шаг 25 м), конфиги и климат — настоящие из репозитория.
use dp_air::weather::{ClimateGrids, GRID_NAMES, Weather};
use dp_air::{AirModel, Conditions, Configs, Focus, Formula, Place, PlaceHeader, State};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn collect(dir: &Path, prefix: &str, out: &mut Vec<(String, String)>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        let name = format!("{prefix}{}", p.file_name().unwrap().to_string_lossy());
        if p.is_dir() {
            collect(&p, &format!("{name}/"), out);
        } else if p.extension().is_some_and(|x| x == "json") {
            out.push((name.trim_end_matches(".json").to_string(), std::fs::read_to_string(&p).unwrap()));
        }
    }
}

/// Конфиги игры как есть (недетерминированный режим, потоки по умолчанию игры).
fn configs() -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    files.sort();
    Configs::new(files)
}

fn unpack(file: &[u8]) -> Vec<u8> {
    let u = |o: usize| u32::from_le_bytes([file[o], file[o + 1], file[o + 2], file[o + 3]]) as usize;
    let (raw, comp) = (u(48), u(52));
    let head = file[..64].to_vec();
    if file.len() != 64 + comp {
        return head;
    }
    let mut out = Vec::new();
    let mut body = &file[64..];
    match brotli_decompressor::BrotliDecompress(&mut body, &mut out) {
        Ok(()) if out.len() == raw => {
            let mut v = head;
            v.extend_from_slice(&out);
            v
        }
        _ => head,
    }
}

fn weather() -> Arc<Weather> {
    let names = [("hh1", "dew_point_1deg"), ("hh2", "upper_air_1deg"), ("hh5", "surface_t_1deg"), ("hh6", "upper_misc_1deg")];
    let items: Vec<(&str, Vec<u8>)> = GRID_NAMES
        .iter()
        .map(|g| {
            let n = names.iter().find(|(k, _)| k == g).unwrap().1;
            (*g, unpack(&std::fs::read(repo().join("data/climate").join(format!("{n}.bin"))).unwrap()))
        })
        .collect();
    let refs: Vec<(&str, &[u8])> = items.iter().map(|(n, b)| (*n, b.as_slice())).collect();
    let files: Vec<(String, String)> = ["atmosphere", "weather_model", "surface_heat", "world"]
        .iter()
        .map(|n| (n.to_string(), std::fs::read_to_string(repo().join("configs").join(format!("{n}.json"))).unwrap()))
        .collect();
    Arc::new(Weather::new(&Configs::new(files), ClimateGrids::from_bytes(&refs)).unwrap())
}

fn hills(x: f64, z: f64) -> f64 {
    1300.0 + 150.0 * (x / 700.0).sin() * (z / 900.0).cos()
}

fn place(n: usize) -> Place {
    let sp = 25.0f64;
    let half = sp * (n - 1) as f64 / 2.0;
    let h = format!(
        r#"{{"version":1,"loc":{{"id":"rig","center_lat":51.5,"center_lon":86.5,"utc_offset_h":6.0,"month":7,"day":15}},
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
    "start_hour":14,"speed":1,"quantum_h":0.25,"inflow_mode":"inflow","rebuild":false}"#;

fn median(v: &mut [f64]) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[v.len() / 2]
}

fn once(n: usize, w: &Arc<Weather>) -> Value {
    let mut m = Formula::new();
    m.configure(&configs(), 7).unwrap();
    m.set_weather(w.clone());
    m.set_conditions(&Conditions::from_json(FORECAST).unwrap()).unwrap();
    m.set_focuses(&[Focus { pos: [0.0, 300.0, 0.0], weight: 1.0 }]).unwrap();
    m.set_static_thermals(&[[100.0, 100.0, 3.0, 150.0]], 0).unwrap();
    let t0 = Instant::now();
    m.load_place(place(n)).unwrap();
    while m.status().state == State::Loading {
        assert!(t0.elapsed() < Duration::from_secs(1800), "no Ready");
        std::thread::sleep(Duration::from_millis(2));
    }
    let ready_s = t0.elapsed().as_secs_f64();
    let state = format!("{:?}", m.status().state);
    let mut steps = Vec::new();
    for k in 1..=60 {
        let t = Instant::now();
        m.advance_to(k as f64 / 60.0).unwrap();
        steps.push(t.elapsed().as_secs_f64() * 1e3);
    }
    let first = steps[0];
    let mx_rest = steps[1..].iter().cloned().fold(0.0, f64::max);
    let med_rest = median(&mut steps[1..].to_vec());
    let mut c = Vec::new();
    m.cores([0.0, 300.0, 0.0], 30000.0, &mut c);
    json!({"ready_s": ready_s, "state": state, "first_ms": first, "rest_median_ms": med_rest, "rest_max_ms": mx_rest,
           "first_air_builds": m.first_air_builds(), "cores": c.len()})
}

fn main() {
    let mut n = 1201usize;
    let mut reps = 3usize;
    for a in std::env::args().skip(1) {
        if let Some(v) = a.strip_prefix("--n=") { n = v.parse().unwrap(); }
        if let Some(v) = a.strip_prefix("--reps=") { reps = v.parse().unwrap(); }
    }
    let w = weather();
    let runs: Vec<Value> = (0..reps).map(|_| once(n, &w)).collect();
    let mut f: Vec<f64> = runs.iter().map(|r| r["first_ms"].as_f64().unwrap()).collect();
    let med = median(&mut f);
    println!("{}", json!({"n": n, "size_km": 0.025 * (n - 1) as f64, "reps": runs, "first_ms_median": med}));
}
