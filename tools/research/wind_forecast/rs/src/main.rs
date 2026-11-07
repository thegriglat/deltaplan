//! WF-1/WF-2: поле у старта (один проход, приток k = 1), только Rust (dp-air без Godot). До WF-2 крейт считал и режим start
//! (подбор k) — его числа в summary.json; WF-2 сверяет новый код с прежним inflow (compare_after.py).
//! wf1-scan <корень репозитория> <out.json> [имя…]; фикстуры мест — tests/fixtures/wind/places, конфиги — configs/.
use dp_air::fixtures::read_place;
use dp_air::{AirModel, Conditions, Focus, Formula, SampleMode, State};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::time::{Duration, Instant};

struct Spec {
    name: &'static str,
    place: &'static str,
    site: &'static str,
    wind_ms: f64,
    from: f64,
    hour: f64,
    temp: f64,
    sky: &'static str,
}

const SPECS: &[Spec] = &[
    Spec { name: "ridge_west", place: "training_island", site: "ridge_west", wind_ms: 6.0, from: 270.0, hour: 12.0, temp: 20.0, sky: "overcast" },
    Spec { name: "thermal_plain", place: "training_island", site: "thermal_plain", wind_ms: 2.0, from: 180.0, hour: 12.0, temp: 25.0, sky: "partly" },
    Spec { name: "landing_hill", place: "training_island", site: "landing_hill", wind_ms: 1.0, from: 270.0, hour: 9.0, temp: 22.0, sky: "clear" },
    Spec { name: "lee_bowl", place: "training_island", site: "lee_bowl", wind_ms: 8.5, from: 270.0, hour: 12.0, temp: 20.0, sky: "overcast" },
    Spec { name: "ongudai", place: "ongudai", site: "kayancha_south", wind_ms: 6.0, from: 151.0, hour: 12.0, temp: 24.0, sky: "clear" },
    Spec { name: "ongudai_back", place: "ongudai", site: "kayancha_south", wind_ms: 6.0, from: 331.0, hour: 12.0, temp: 24.0, sky: "clear" },
    Spec { name: "volc_east_cliffs", place: "volcano_island", site: "east_cliffs", wind_ms: 6.0, from: 110.0, hour: 12.0, temp: 27.0, sky: "partly" },
    Spec { name: "volc_crater_ridge", place: "volcano_island", site: "crater_ridge", wind_ms: 6.0, from: 110.0, hour: 12.0, temp: 27.0, sky: "partly" },
];

fn ground(p: &dp_air::Place, x: f64, z: f64) -> f64 {
    let g = &p.header().grid;
    let fx = ((x - g.origin_x) / g.spacing).clamp(0.0, (g.width - 1) as f64 - 1e-6);
    let fz = ((z - g.origin_z) / g.spacing).clamp(0.0, (g.height - 1) as f64 - 1e-6);
    let (i, j) = (fx.floor() as usize, fz.floor() as usize);
    let (tx, tz) = (fx - i as f64, fz - j as f64);
    let w = g.width as usize;
    let h = p.heights();
    let at = |a: usize, b: usize| f64::from(h[b * w + a]);
    (at(i, j) * (1.0 - tx) + at(i + 1, j) * tx) * (1.0 - tz) + (at(i, j + 1) * (1.0 - tx) + at(i + 1, j + 1) * tx) * tz
}

fn run(root: &PathBuf, s: &Spec, cfg: &dp_air::Configs) -> Result<Value, String> {
    let pj = root.join(format!("tests/fixtures/wind/places/{}.json", s.place));
    let place = read_place(&pj).map_err(|e| e.to_string())?;
    let site = place.header().start_sites.iter().find(|_| true);
    let _ = site;
    let ids: Value = serde_json::from_str(&std::fs::read_to_string(&pj).unwrap()).unwrap();
    let st = ids["start_sites"].as_array().unwrap().iter().find(|x| x["id"] == s.site).ok_or("site")?.clone();
    let (sx, sz, sh) = (st["x"].as_f64().unwrap(), st["z"].as_f64().unwrap(), st["h_msl"].as_f64().unwrap());
    let gs = ground(&place, sx, sz);
    let cond = json!({
        "forecast": {"sky": s.sky, "temperature_c": s.temp, "wind_from_deg": s.from, "wind_speed_kmh": s.wind_ms * 3.6},
        "start_hour": s.hour, "speed": 1.0, "quantum_h": 0.0166666666666667, "blend_s": null, "rebuild": false,
        "overrides": {}, "wind_ref": {"ref_msl": sh, "gain_per_km": 0.6}
    });
    let c = Conditions::from_json(&cond.to_string()).map_err(|e| e.to_string())?;
    let mut m = Formula::new().with_deterministic(true);
    m.configure(cfg, 1).map_err(|e| e.to_string())?;
    let t0 = Instant::now();
    m.load_place(place.clone()).map_err(|e| e.to_string())?;
    m.set_conditions(&c).map_err(|e| e.to_string())?;
    m.set_focuses(&[Focus { pos: [sx as f32, gs as f32, sz as f32], weight: 1.0 }]).map_err(|e| e.to_string())?;
    m.start_at(0.0).map_err(|e| e.to_string())?;
    let mut runs_max = 0u32;
    loop {
        let stt = m.status();
        runs_max = runs_max.max(stt.runs);
        match stt.state {
            State::Ready => break,
            State::Failed => return Err(format!("failed: {}", stt.reason)),
            _ => {}
        }
        if t0.elapsed() > Duration::from_secs(1800) {
            return Err("timeout".into());
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    let ready_s = t0.elapsed().as_secs_f64();
    let rep = m.report().ok_or("no report")?;
    let sample = |x: f64, z: f64, agl: f64| -> [f32; 4] {
        let y = ground(&place, x, z) + agl;
        let mut o = [[0f32; 4]; 1];
        m.sample_many(&[[x as f32, y as f32, z as f32]], SampleMode::Mean, &mut o);
        o[0]
    };
    let u10 = sample(sx, sz, 10.0);
    let hs = |v: [f32; 4]| f64::from(v[0]).hypot(f64::from(v[2]));
    let mut mx = [0.0f64; 3];
    let n = 24i32;
    for iz in -n..=n {
        for ix in -n..=n {
            for (a, agl) in [30.0, 100.0, 200.0].iter().enumerate() {
                let v = hs(sample(sx + f64::from(ix) * 100.0, sz + f64::from(iz) * 100.0, *agl));
                if v > mx[a] {
                    mx[a] = v;
                }
            }
        }
    }
    Ok(json!({
        "name": s.name, "place": s.place, "site": s.site, "wind_ms": s.wind_ms, "from": s.from, "hour": s.hour,
        "start": {"x": sx, "z": sz, "ground_m": gs, "h_msl": sh},
        "u_start10": hs(u10), "w_start10": u10[1],
        "passes_run": rep.passes.len(),
        "wall_s_report": rep.wall_s, "ready_s": ready_s, "runs_max": runs_max,
        "umax_30": mx[0], "umax_100": mx[1], "umax_200": mx[2],
        "source": format!("{:?}", rep.source), "windows": rep.windows.len(), "windows_error": rep.windows_error,
    }))
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let root = PathBuf::from(&a[1]);
    let out = PathBuf::from(&a[2]);
    let names: Vec<&String> = a[3..].iter().collect();
    let cfg = dp_stand::setup::load_configs(&root.join("configs")).expect("configs");
    let mut rows = Vec::new();
    for s in SPECS.iter().filter(|s| names.is_empty() || names.iter().any(|n| *n == s.name)) {
        match run(&root, s, &cfg) {
            Ok(v) => {
                eprintln!("{} u={:.2} passes={} ready={:.1}s", s.name, v["u_start10"].as_f64().unwrap(), v["passes_run"], v["ready_s"].as_f64().unwrap());
                rows.push(v)
            }
            Err(e) => {
                eprintln!("{} ERROR {e}", s.name);
                rows.push(json!({"name": s.name, "error": e}))
            }
        }
        std::fs::write(&out, serde_json::to_string_pretty(&json!({"rows": rows})).unwrap()).unwrap();
    }
}
