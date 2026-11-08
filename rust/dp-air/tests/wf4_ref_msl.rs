//! WF-4 (WF-К1 v3): опорная высота ветра прогноза без `wind_ref` в условиях - отметка открытой
//! местности места (`valley_msl_m`), а не отметка старта; на ней скорость на 10 м над землёй равна
//! скорости прогноза; явный `wind_ref` перекрывает.
mod common;

use common::real_weather;
use dp_air::field::weather_core::context;
use dp_air::fixtures::read_place;
use dp_air::terms::Terms;
use dp_air::{Conditions, Configs};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn configs() -> Arc<Configs> {
    let dir = root().join("configs");
    let mut files = Vec::new();
    for n in ["atmosphere", "weather_model", "world", "surface_heat"] {
        files.push((
            n.to_string(),
            std::fs::read_to_string(dir.join(format!("{n}.json"))).unwrap(),
        ));
    }
    for n in ["weak", "medium", "strong"] {
        files.push((
            format!("weather/{n}"),
            std::fs::read_to_string(dir.join(format!("weather/{n}.json"))).unwrap(),
        ));
    }
    Arc::new(Configs::new(files))
}

fn cond(wind_ref: serde_json::Value) -> Conditions {
    Conditions::from_json(
        &json!({
            "forecast": {"temperature_c": 24.0, "wind_speed_kmh": 21.6, "wind_from_deg": 151.0, "sky": "clear"},
            "start_hour": 12.0, "speed": 1.0, "quantum_h": 0.1, "wind_ref": wind_ref,
        })
        .to_string(),
    )
    .unwrap()
}

fn terms(place: &str) -> (Terms, dp_air::Place) {
    let p = read_place(&root().join(format!("tests/fixtures/wind/places/{place}.json"))).unwrap();
    let mut t = Terms::default();
    t.configure(&configs(), 1);
    t.set_weather(real_weather());
    t.set_place(Some(&p));
    (t, p)
}

#[test]
fn wf4_ref_msl_is_valley() {
    for name in ["ongudai", "volcano_island"] {
        let (mut t, p) = terms(name);
        let valley = context(&p).valley_msl_m;
        let start = p.header().start_sites[0].h_msl;
        t.set_conditions(&cond(serde_json::Value::Null));
        assert!(valley.is_finite(), "{name}: valley");
        assert_eq!(t.wind.ref_msl, valley, "{name}: опора - долина места");
        if (start - valley).abs() > 1.0 {
            assert_ne!(t.wind.ref_msl, start, "{name}: не отметка старта");
        }
        // на отметке долины 10 м над землёй - скорость прогноза
        let v = t.wind.speed_at_pos(10.0, valley);
        assert!((v - 6.0).abs() < 0.06, "{name}: {v} вместо 6 м/с");
        // выше долины ветер не слабеет (рост - по климату места; на острове у моря он может быть нулевым)
        assert!(t.wind.speed_at_pos(10.0, valley + 1000.0) >= v, "{name}: рост");
        println!("WF4 {name}: gain={:.3} valley={valley:.1} start={start:.1} v_valley={v:.3} v_start={:.3}", t.wind.altitude_factor(valley + 1000.0) - 1.0, t.wind.speed_at_pos(10.0, start));
    }
}

#[test]
fn wf4_ref_msl_explicit_wind_ref_wins() {
    let (mut t, _) = terms("ongudai");
    t.set_conditions(&cond(json!({"ref_msl": 1234.0, "gain_per_km": 0.3})));
    assert_eq!(t.wind.ref_msl, 1234.0);
}
