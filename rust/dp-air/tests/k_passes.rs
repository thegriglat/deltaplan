//! RW-6w: `k` второго прохода у полей с `inflow_mode = start` против запечённых файлов.
//! Диагностика и приёмка: `k` крейта = `k` файла с точностью 1e-3, `U` над стартом по уровням
//! крейта и по уровням файла (`k_file` даёт `U2 ≈ u10`). Тяжёлое: release, по одному.
//! `cargo test --release -p dp-air --test k_passes -- --include-ignored --nocapture`
use dp_air::field::baked::parse_baked;
use dp_air::field::runtime::*;
use dp_air::field::wind_field::Field;
use dp_air::fixtures::read_place;
use dp_air::{AirModel, Conditions, Configs, Focus, Formula, Place, State};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
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

/// Конфиги игры; `patch` правит разобранный `atmosphere.json`.
fn configs_with(patch: impl Fn(&mut Value)) -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere.json" {
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

fn wait_ready(m: &mut Formula, limit: f64) {
    let t0 = Instant::now();
    loop {
        let s = m.status();
        match s.state {
            State::Ready => {
                m.poll();
                return;
            }
            State::Failed => panic!("Failed: {}", s.reason),
            _ => {}
        }
        assert!(t0.elapsed().as_secs_f64() < limit, "no Ready in {limit} s");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// Условия набора погоды запечённого поля (`AirBakedField.conditions_of`).
fn baked_conditions(w: &Value) -> Conditions {
    let num = |k: &str| w[k].as_f64().unwrap_or_else(|| panic!("weather.{k}"));
    let inflow = w["wind_ref"].as_str().unwrap_or("start") == "inflow";
    Conditions::from_json(
        &json!({
            "forecast": {
                "temperature_c": num("temperature_c"),
                "wind_speed_kmh": num("wind_speed_ms") * 3.6,
                "wind_from_deg": num("wind_from_deg"),
                "sky": w["sky"].as_str().unwrap(),
            },
            "start_hour": num("start_hour"),
            "speed": 1.0,
            "quantum_h": 0.5,
            "blend_s": null,
            "rebuild": false,
            "inflow_mode": if inflow { "inflow" } else { "start" },
        })
        .to_string(),
    )
    .unwrap()
}

/// Один файл: `k` и `U` по проходам крейта против `k` файла и `U` по уровням файла.
fn k_field(loc: &str, site: &str) {
    let dir = repo().join("data/locations").join(loc).join("air");
    let head = std::fs::read_to_string(dir.join(format!("{site}.json"))).unwrap();
    let bin = std::fs::read(dir.join(format!("{site}.bin"))).unwrap();
    let baked = parse_baked(&head, &bin).unwrap_or_else(|e| panic!("{loc}/{site}: {}", e.msg));
    let key = &baked.key;
    let cond = baked_conditions(&key["weather"]);
    let start = key["start"].as_array().unwrap();
    let (sx, sz) = (
        start[0].as_f64().unwrap() as f32,
        start[1].as_f64().unwrap() as f32,
    );
    let u10 = key["weather"]["wind_speed_ms"].as_f64().unwrap();
    let wdir = key["weather"]["wind_from_deg"].as_f64().unwrap();
    let cfg = configs_with(|v| {
        v["air"]["deterministic"] = json!(true);
        v["air"]["tol_scale"] = json!(1.0);
        v["air"]["threads"] = json!(8);
        v["air"]["timeout_s"] = json!(1800.0);
    });
    let pl = place(loc);
    let h = ground_height(&pl, sx, sz);
    let file_levels: Vec<Arc<Field>> = baked.levels.iter().cloned().map(Arc::new).collect();
    let u_file = start_speed_levels(&file_levels, &pl, 30.0, Some([sx, sz]), u10, wdir);
    let mut m = Formula::new();
    m.configure(&cfg, 1).unwrap();
    m.set_conditions(&cond).unwrap();
    m.set_focuses(&[Focus {
        pos: [sx, h + 10.0, sz],
        weight: 1.0,
    }])
    .unwrap();
    m.load_place(pl.clone()).unwrap();
    wait_ready(&mut m, 1800.0);
    let r = m.report().unwrap();
    let k_file = baked.inflow_k;
    let got = m.clip().expect("окна клипмапа").levels();
    let u_got = start_speed_levels(&got, &pl, 30.0, Some([sx, sz]), u10, wdir);
    eprintln!(
        "K {loc}/{site}: u10 {u10}; проходы крейта {:?}; k {:.5} (файл {k_file:.5}); U2 крейта {u_got:.4}, U2 файла {u_file:.4}",
        r.log,
        m.inflow_k()
    );
    let dk = m.inflow_k() - k_file;
    assert!(dk.abs() < 1e-3, "{loc}/{site}: k расходится на {dk}");
}

macro_rules! k_tests {
    ($($name:ident: $loc:literal, $site:literal;)*) => {$(
        #[test]
        #[ignore = "release, тяжёлый"]
        fn $name() {
            k_field($loc, $site);
        }
    )*};
}

k_tests! {
    k_training_island_ridge_west: "training_island", "ridge_west";
    k_volcano_island_plateau_landing: "volcano_island", "plateau_landing";
    k_volcano_island_thermal_slope: "volcano_island", "thermal_slope";
}
