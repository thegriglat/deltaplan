//! SWG-3: время Пикара крейта (Formula, dp-air без Godot) на окнах 100/50 м игры: холодная загрузка (область + окна) и
//! пересчёт при смене ветра (+30°, скорость ×1,2) с тёплого старта.
//! swg3-picard <корень репозитория> <out.json> <threads> <tol_scale> <wind_ms> <from_deg>
use dp_air::fixtures::read_place;
use dp_air::{AirModel, Conditions, Focus, Formula, State};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn cond(u_ms: f64, from: f64) -> Conditions {
    let c = json!({
        "forecast": {"sky": "clear", "temperature_c": 24.0, "wind_from_deg": from, "wind_speed_kmh": u_ms * 3.6},
        "start_hour": 12.0, "speed": 1.0, "quantum_h": 0.0166666666666667, "blend_s": null, "rebuild": false,
        "overrides": {}
    });
    Conditions::from_json(&c.to_string()).expect("conditions")
}

fn wins(rep: &dp_air::field::runtime::JobReport) -> Vec<Value> {
    rep.windows
        .iter()
        .map(|w| {
            json!({"dx": w.dx, "x0": w.x0, "y0": w.y0, "warm": w.warm, "iters": w.iters,
                   "stop": format!("{:?}", w.stop), "secs": w.secs, "t_s": w.secs.iter().sum::<f64>()})
        })
        .collect()
}

fn passes(rep: &dp_air::field::runtime::JobReport) -> Vec<Value> {
    rep.passes
        .iter()
        .map(|p| {
            json!({"iters": p.iters, "coarse_iters": p.coarse_iters, "secs": p.secs, "win_s": p.win_s, "phase_s": p.phase_s,
                   "phases": p.phases, "frozen_frac": p.frozen_frac, "stop": [format!("{:?}", p.stop[0]), format!("{:?}", p.stop[1])],
                   "start": format!("{:?}", p.start)})
        })
        .collect()
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let root = PathBuf::from(&a[1]);
    let out = PathBuf::from(&a[2]);
    let threads: u64 = a[3].parse().unwrap();
    let tol: f64 = a[4].parse().unwrap();
    let u_ms: f64 = a[5].parse().unwrap();
    let from: f64 = a[6].parse().unwrap();
    let mut cfg = dp_stand::setup::load_configs(&root.join("configs")).expect("configs");
    for (name, text) in cfg.files.iter_mut() {
        if name == "atmosphere" {
            let mut v: Value = serde_json::from_str(text).unwrap();
            v["air"]["threads"] = json!(threads);
            v["air"]["tol_scale"] = json!(tol);
            *text = serde_json::to_string(&v).unwrap();
        }
    }
    let place = read_place(&root.join("tests/fixtures/wind/places/ongudai.json")).expect("place");
    let focus = Focus { pos: [7224.77490234375, 1868.75671386719, 324.689636230469], weight: 1.0 };
    let mut m = Formula::new().with_deterministic(true);
    m.configure(&cfg, 707).expect("configure");

    let t0 = Instant::now();
    m.load_place(place).expect("load_place");
    m.set_conditions(&cond(u_ms, from)).unwrap();
    m.set_focuses(&[focus]).unwrap();
    m.start_at(0.0).unwrap();
    loop {
        let s = m.status();
        match s.state {
            State::Ready => break,
            State::Failed => panic!("failed: {}", s.reason),
            _ => {}
        }
        if t0.elapsed() > Duration::from_secs(3000) {
            panic!("timeout");
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    let cold_wall = t0.elapsed().as_secs_f64();
    let rc = m.report().expect("report");
    let cold = json!({"wall_s": cold_wall, "report_wall_s": rc.wall_s, "source": format!("{:?}", rc.source),
        "passes": passes(&rc), "windows": wins(&rc), "windows_error": rc.windows_error, "notes": rc.notes});
    eprintln!("cold wall {cold_wall:.1}s passes {} windows {}", rc.passes.len(), rc.windows.len());

    // смена ветра: +30°, скорость ×1,2; пересчёт в полёте с тёплого старта (advance_to ждёт фон: deterministic)
    m.set_conditions(&cond(u_ms * 1.2, (from + 30.0) % 360.0)).unwrap();
    let t1 = Instant::now();
    m.advance_to(1.0).unwrap();
    let wc_wall = t1.elapsed().as_secs_f64();
    let rw = m.report().expect("report2");
    let cur = m.current().map(|c| json!({"u10": c.u10, "wdir": c.wdir}));
    let wc = json!({"wall_s": wc_wall, "report_wall_s": rw.wall_s, "source": format!("{:?}", rw.source),
        "passes": passes(&rw), "windows": wins(&rw), "windows_error": rw.windows_error, "cur": cur});
    eprintln!("wind_change wall {wc_wall:.1}s report {:.1}s passes {} windows {}", rw.wall_s, rw.passes.len(), rw.windows.len());
    let res = json!({"threads": threads, "tol_scale": tol, "u10": u_ms, "from_deg": from, "cold": cold, "wind_change": wc});
    std::fs::write(&out, serde_json::to_string_pretty(&res).unwrap()).unwrap();
}
