//! RW-P13: `Status.run/runs` — номер прогона решателя и их число по плану. На этапах с
//! итерациями `1 ≤ run ≤ runs`, `run` не убывает, (счёт `iters` с нуля при входе — в `StageCounter::enter`), вне
//! этапов `run = runs = 0`; `Calm` — 0, 0.
use dp_air::field::runtime::Faults;
use dp_air::{AirModel, Calm, Conditions, Configs, Focus, Formula, Place, PlaceHeader, State};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const NO_WIN: Faults = Faults {
    coarse: false,
    fail_pass: None,
    no_phase: false,
    no_windows: true,
};

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

fn configs() -> Configs {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut files = Vec::new();
    collect(&root.join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere.json" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = serde_json::json!(true);
            v["air"]["domain_l_m"] = serde_json::json!(7200.0);
            v["air"]["threads"] = serde_json::json!(4);
            v["air"]["tol_scale"] = serde_json::json!(5.0);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

fn place() -> Place {
    let header = r#"{"version":1,"loc":{"id":"training_island","center_lat":43.2,"center_lon":34.0,
"utc_offset_h":2.0,"month":7,"day":15},"model_hash":"stage-runs-1","grid":{"origin_x":-10000,"origin_z":-10000,"spacing":25,
"width":801,"height":801},"surface_classes":{"grass":1},
"start_sites":[{"x":3510.0,"z":-1510.0,"h_msl":100.0}]}"#;
    let h = PlaceHeader::from_json(header).unwrap();
    let n = h.cells();
    Place::new(h, vec![100.0; n], vec![0; n], vec![1; n], vec![0.5; n]).unwrap()
}

#[test]
fn run_counts_solver_entries_and_resets_iters() {
    // без кеша на диске: поле считается по-настоящему (замок — один счёт на процесс)
    let mut m = Formula::new().with_faults(NO_WIN);
    m.configure(&configs(), 1).unwrap();
    m.set_conditions(
        &Conditions::from_json(
            r#"{"forecast":{"temperature_c":22,"wind_speed_kmh":3.6,"wind_from_deg":270,"sky":"clear"},
"quantum_h":1,"start_hour":9,"speed":1,"blend_s":null,"rebuild":false}"#,
        )
        .unwrap(),
    )
    .unwrap();
    m.set_focuses(&[Focus {
        pos: [3510.0, 110.0, -1510.0],
        weight: 1.0,
    }])
    .unwrap();
    m.load_place(place()).unwrap();
    let mut last_run = 0u32;
    let mut seen_iter_stage = false;
    let t0 = Instant::now();
    loop {
        m.poll();
        let s = m.status();
        let solver = matches!(s.stage.as_str(), "coarse" | "solve_mech" | "solve_heat");
        if solver {
            seen_iter_stage = true;
            assert!(s.run >= 1 && s.run <= s.runs, "{s:?}");
            assert!(s.run >= last_run, "run убыл: {s:?}");
            last_run = s.run;
        } else {
            assert_eq!((s.run, s.runs), (0, 0), "вне решателя: {s:?}");
        }
        if s.state == State::Ready {
            break;
        }
        assert_ne!(s.state, State::Failed, "{}", s.reason);
        assert!(t0.elapsed() < Duration::from_secs(900), "no field in 900 s");
        std::thread::sleep(Duration::from_millis(1));
    }
    assert!(seen_iter_stage, "этап решателя не замечен опросом");
    assert!(
        last_run >= 2,
        "mech и heat — минимум два прогона: {last_run}"
    );
}

#[test]
fn calm_has_no_runs() {
    let c = Calm::new();
    let s = c.status();
    assert_eq!((s.run, s.runs, s.iters), (0, 0, 0));
}
