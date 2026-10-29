//! RW-14c: `AirModel::set_weather` / `place_context` (W4 v10) и климат места из `Weather` (W5 v10).
mod common;

use common::{no_grids_weather, real_weather};
use dp_air::fixtures::{read_case, read_place};
use dp_air::{AirModel, Calm, Conditions, Configs, Formula, Place};
use serde_json::Value;
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
            out.push((name, std::fs::read_to_string(&p).unwrap()));
        }
    }
}

fn configs() -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    files.sort();
    Configs::new(files)
}

fn place(name: &str) -> Place {
    read_place(&repo().join(format!("tests/fixtures/wind/places/{name}.json"))).unwrap()
}

fn forecast_conditions() -> Conditions {
    read_case(&repo().join("tests/fixtures/wind/cases/ongudai_day_1.json"))
        .unwrap()
        .conditions
}

fn climate_src(m: &Formula) -> Value {
    let w: Value = serde_json::from_str(&m.weather_json()).unwrap();
    w["_derived"]["climate_src"].clone()
}

#[test]
fn place_context_follows_the_loaded_place() {
    let mut m = Formula::new();
    m.configure(&configs(), 1).unwrap();
    assert!(m.place_context().is_none());
    m.load_place(place("ongudai")).unwrap();
    let c = m.place_context().expect("место загружено");
    let h = place("ongudai").header().loc.clone();
    assert_eq!(
        (c.lat, c.lon, c.utc_offset_h),
        (h.center_lat, h.center_lon, h.utc_offset_h)
    );
    assert_eq!((c.month, c.day), (h.month as i64, h.day as i64));
    assert!(c.valley_msl_m.is_finite() && c.mean_msl_m >= c.valley_msl_m);
    m.unload_place();
    assert!(m.place_context().is_none());
    // по умолчанию (Calm) - нет контекста, set_weather ничего не делает
    let mut calm = Calm::default();
    calm.set_weather(real_weather());
    assert!(calm.place_context().is_none());
}

#[test]
fn forecast_climate_comes_from_weather() {
    let c = forecast_conditions();
    // без Weather - запасные значения (ячейка без сеток)
    let mut m = Formula::new();
    m.configure(&configs(), 1).unwrap();
    m.load_place(place("ongudai")).unwrap();
    m.set_conditions(&c).unwrap();
    let none = climate_src(&m);
    assert_eq!(none["hh1"], "none", "{none}");
    // Weather с настоящими сетками, после условий: погода пересобирается
    m.set_weather(real_weather());
    let data = climate_src(&m);
    assert_eq!(data["hh1"], "data", "{data}");
    assert_eq!(data["hh6"], "data", "{data}");
    // Weather без сеток - те же запасные значения
    let mut m2 = Formula::new();
    m2.configure(&configs(), 1).unwrap();
    m2.set_weather(no_grids_weather());
    m2.load_place(place("ongudai")).unwrap();
    m2.set_conditions(&c).unwrap();
    assert_eq!(climate_src(&m2), none);
}

#[test]
fn weather_is_send_sync_and_shared_by_arc() {
    fn is<T: Send + Sync>() {}
    is::<dp_air::weather::Weather>();
    let w = real_weather();
    let w2 = w.clone();
    assert!(std::sync::Arc::strong_count(&w2) >= 2);
}
