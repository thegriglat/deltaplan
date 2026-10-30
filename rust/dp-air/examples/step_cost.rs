//! RW-15: цена шага воздуха (advance_to + set_focuses) на синтетическом месте разного размера.
//!
//! Место как в T9 (`xc_run.gd --synthetic`): плоская земля, шаг 25 м, статичные термики сеткой, без
//! ветра. После READY - 60 игровых секунд шагами 1/60 с с одним фокусом, идущим ~12 м/с; как игра
//! (`Game.tick`): `set_focuses` при сдвиге фокуса на 1 м и более, затем `advance_to`. Печатает
//! `ms_per_game_s_<N>` (только шаг, без подготовки) и `ratio_3041_1041`.
//! Аргументы: размеры узлов через запятую (по умолчанию `1041,3041`), `--secs=<игровых с>`.
use dp_air::{AirModel, Conditions, Configs, Focus, Formula, Place, PlaceHeader, State};
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

fn configs() -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = json!(true);
            // как xc_run.gd: радиусы генерации и физики термиков
            v["thermal"]["generation_radius_m"] = json!(7000.0);
            v["thermal"]["physics_radius_m"] = json!(3000.0);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

/// Плоское место n x n узлов с шагом 25 м, центр в начале координат.
pub fn flat_place(n: usize) -> Place {
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

/// Статичные термики сеткой вдоль курса +x (как `synthetic_thermals`: шаг 2 км, 3 м/с, 100 м).
fn statics(km: f64) -> Vec<[f32; 4]> {
    let mut v = Vec::new();
    let mut s = 1000.0;
    let mut k = 0u32;
    while s < km * 1000.0 + 2000.0 {
        let lat = ((k * 37 % 17) as f64 / 8.0 - 1.0) * 200.0;
        v.push([s as f32, lat as f32, 3.0, 100.0]);
        s += 2000.0;
        k += 1;
    }
    v
}

fn run(n: usize, secs: usize, wind: f64, hz: usize) -> f64 {
    let mut m = Formula::new();
    m.configure(&configs(), 7).unwrap();
    let preset: Value = {
        let mut p: Value = serde_json::from_str(
            &std::fs::read_to_string(repo().join("configs/weather/medium.json")).unwrap(),
        )
        .unwrap();
        p["wind_speed_kmh"] = json!(wind);
        p["thermal_mode"] = json!("static");
        p["static_thermals"] = json!([]);
        p
    };
    let c = format!(
        r#"{{"preset":{preset},"start_hour":12,"speed":1,"blend_s":null,"rebuild":false,"inflow_mode":"inflow"}}"#
    );
    m.set_conditions(&Conditions::from_json(&c).unwrap())
        .unwrap();
    m.set_static_thermals(&statics(30.0), 1).unwrap();
    // фокус идёт на восток из -10 км: на всех размерах остаётся внутри места (1041² - ±13 км)
    let x0 = -10000.0f32;
    let p0 = [x0, 800.0, 0.0];
    m.set_focuses(&[Focus {
        pos: p0,
        weight: 1.0,
    }])
    .unwrap();
    let t0 = Instant::now();
    m.load_place(flat_place(n)).unwrap();
    while m.status().state == State::Loading {
        assert!(t0.elapsed() < Duration::from_secs(1800), "no Ready");
        std::thread::sleep(Duration::from_millis(5));
    }
    let st = m.status();
    assert_eq!(st.state, State::Ready, "{}", st.reason);
    eprintln!("n={n}: READY за {:.1} с", t0.elapsed().as_secs_f64());
    m.start_at(0.0).unwrap();
    m.advance_to(1.0 / hz as f64).unwrap();
    let steps = secs * hz;
    let mut sink = 0.0f32;
    let mut out = [[0.0f32; 4]; 1];
    let t1 = Instant::now();
    for i in 1..=steps {
        let t = i as f64 / hz as f64;
        let pos = [x0 + (12.0 * t) as f32, 800.0, 0.0];
        m.set_focuses(&[Focus { pos, weight: 1.0 }]).unwrap();
        let ta = Instant::now();
        m.advance_to(t).unwrap();
        let dt = ta.elapsed().as_secs_f64();
        if dt > 0.1 {
            eprintln!("n={n}: advance_to t={t:.1} с занял {:.2} с", dt);
        }
        m.sample_many(&[pos], dp_air::SampleMode::Full, &mut out);
        sink += out[0][1];
        if i % (hz / 10).max(1) == 0 {
            let mut d = [0.0f32; 1];
            m.cloud_density_many(&[pos], &mut d);
            let mut cs = Vec::new();
            m.cores(pos, 2500.0, &mut cs);
            let mut cl = Vec::new();
            m.clouds(pos, 8000.0, &mut cl);
            sink += d[0] + cs.len() as f32 + cl.len() as f32;
        }
    }
    let ms = t1.elapsed().as_secs_f64() * 1000.0 / secs as f64;
    eprintln!("n={n}: sink={sink}");
    ms
}

fn flag(name: &str) -> Option<String> {
    std::env::args().find_map(|a| a.strip_prefix(name).map(str::to_string))
}

fn main() {
    let mut sizes = vec![1041usize, 3041];
    let mut secs = 1000usize;
    for a in std::env::args().skip(1) {
        if let Some(s) = a.strip_prefix("--secs=") {
            secs = s.parse().unwrap();
        } else if a.starts_with(|c: char| c.is_ascii_digit()) {
            sizes = a.split(',').map(|s| s.parse().unwrap()).collect();
        }
    }
    let wind = flag("--wind=").map_or(0.0, |v| v.parse().unwrap());
    let hz = flag("--hz=").map_or(60, |v| v.parse().unwrap());
    let mut res = Vec::new();
    for &n in &sizes {
        let ms = run(n, secs, wind, hz);
        println!("ms_per_game_s_{n}={ms:.2}");
        res.push((n, ms));
    }
    let get = |n| res.iter().find(|r| r.0 == n).map(|r| r.1);
    if let (Some(a), Some(b)) = (get(1041), get(3041)) {
        println!("ratio_3041_1041={:.3}", b / a);
    }
}
