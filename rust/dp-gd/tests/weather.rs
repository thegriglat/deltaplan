//! `DpWeather` (W12 v2) без Godot: вызовы моста дают те же числа/JSON, что `Weather` напрямую.
use dp_air::weather::{ClimateGrids, PlaceCtx, Weather, hour_at, valley_of};
use dp_air::{Calm, Configs, Forecast};
use dp_gd::bridge::{BAD_INPUT, Bridge, OK};
use dp_gd::weather::WeatherBridge;
use serde_json::Value;
use std::path::{Path, PathBuf};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn pairs() -> Vec<String> {
    ["atmosphere", "weather_model", "surface_heat", "world"]
        .iter()
        .flat_map(|n| {
            let t = std::fs::read_to_string(repo().join("configs").join(format!("{n}.json")));
            [n.to_string(), t.unwrap()]
        })
        .collect()
}

fn u32_at(b: &[u8], o: usize) -> usize {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]) as usize
}

/// Как игра: файл -> 64 байта заголовка + распакованное тело.
fn unpack(file: &[u8]) -> Vec<u8> {
    let (raw, comp) = (u32_at(file, 48), u32_at(file, 52));
    let mut head = file[..64].to_vec();
    let mut out = Vec::new();
    let mut body = &file[64..64 + comp];
    brotli_decompressor::BrotliDecompress(&mut body, &mut out).unwrap();
    assert_eq!(out.len(), raw);
    head.extend_from_slice(&out);
    head
}

const GRIDS: [(&str, &str); 4] = [
    ("hh1", "dew_point_1deg"),
    ("hh2", "upper_air_1deg"),
    ("hh5", "surface_t_1deg"),
    ("hh6", "upper_misc_1deg"),
];

fn grid_data() -> (Vec<String>, Vec<Vec<u8>>) {
    let names = GRIDS.iter().map(|(k, _)| k.to_string()).collect();
    let bytes = GRIDS
        .iter()
        .map(|(_, f)| unpack(&std::fs::read(repo().join(format!("data/climate/{f}.bin"))).unwrap()))
        .collect();
    (names, bytes)
}

fn both() -> (WeatherBridge, Weather) {
    let (names, bytes) = grid_data();
    let slices: Vec<&[u8]> = bytes.iter().map(Vec::as_slice).collect();
    let mut b = WeatherBridge::default();
    assert_eq!(b.configure(&pairs(), &names, &slices), OK);
    let p = pairs();
    let cfg = Configs::new(p.chunks(2).map(|c| (c[0].clone(), c[1].clone())).collect());
    let items: Vec<(&str, &[u8])> = names.iter().map(String::as_str).zip(slices).collect();
    (
        b,
        Weather::new(&cfg, ClimateGrids::from_bytes(&items)).unwrap(),
    )
}

const CTX: &str = r#"{"month":7,"day":15,"lat":50.0,"lon":86.0,"utc_offset_h":7.0,
"valley_msl_m":400.0,"mean_msl_m":900.0}"#;

fn ctx() -> PlaceCtx {
    PlaceCtx {
        month: 7,
        day: 15,
        lat: 50.0,
        lon: 86.0,
        utc_offset_h: 7.0,
        valley_msl_m: 400.0,
        mean_msl_m: 900.0,
        start_msl_m: f64::NAN,
    }
}

#[test]
fn before_configure_nothing_is_computed() {
    let b = WeatherBridge::default();
    assert!(b.typical_max_c(7, 15, 50.0, 86.0, f64::NAN).is_nan());
    assert!(b.sunset_h(25.0, CTX).is_nan());
    assert!(b.quantum_h().is_nan());
    assert_eq!(b.diurnal_state(25.0, 12.0, CTX), "");
    assert_eq!(b.reference_context(), "");
    assert_eq!(b.derive("{}", CTX, 12.0), "{}");
    assert_eq!(b.climate_cell(50.0, 86.0, 7, 15), "{}");
    assert!(b.sky_params("clear").is_empty());
    assert!(b.arc().is_none());
}

#[test]
fn configure_checks_input() {
    let mut b = WeatherBridge::default();
    assert_eq!(b.configure(&["x".into()], &[], &[]), BAD_INPUT);
    assert_eq!(b.configure(&pairs(), &["hh1".into()], &[]), BAD_INPUT);
    assert_ne!(
        b.configure(&["weather_model".into(), "{".into()], &[], &[]),
        OK
    );
    assert!(b.arc().is_none());
}

#[test]
fn scalars_match_the_crate() {
    let (b, w) = both();
    let c = ctx();
    assert_eq!(
        b.typical_max_c(7, 15, 50.0, 86.0, 400.0),
        w.typical_max_c(7, 15, 50.0, 86.0, 400.0)
    );
    assert_eq!(b.sunrise_h(25.0, CTX), w.sunrise_h(25.0, &c));
    assert_eq!(b.sunset_h(25.0, CTX), w.sunset_h(25.0, &c));
    assert_eq!(
        b.air_temp_c(15.0, 25.0, 1500.0, CTX),
        w.air_temp_c(15.0, 25.0, 1500.0, &c)
    );
    assert_eq!(
        b.water_temp_c(7, 15, 300.0, CTX),
        w.water_temp_c(7, 15, 300.0, &c)
    );
    assert_eq!(b.quantum_h(), w.quantum_h());
    assert_eq!(
        b.hour_at(8.0, 60.0, 600.0, 0.0),
        hour_at(8.0, 60.0, 600.0, &w.world_time())
    );
    assert_eq!(b.hour_at(8.0, 60.0, 1e9, 0.0), w.world_time().max_hour);
    let s = [300.0f32, 100.0, 500.0, 200.0, 400.0];
    assert_eq!(b.valley_of(&s, 0.1), valley_of(&s, 0.1));
    let (cover, heat) = w.sky_params("scattered");
    assert_eq!(b.sky_params("scattered"), vec![cover as f32, heat as f32]);
    assert!(b.air_temp_c(15.0, 25.0, 1500.0, "{}").is_finite());
}

#[test]
fn json_matches_the_crate() {
    let (b, w) = both();
    let c = ctx();
    let fc =
        r#"{"temperature_c":24.0,"wind_speed_kmh":18.0,"wind_from_deg":250.0,"sky":"scattered"}"#;
    let f: Forecast = serde_json::from_str(fc).unwrap();
    let direct = Value::Object(w.derive(&f, &c, 14.0));
    // сравнение строк: разбор serde без float_roundtrip теряет последний разряд
    let got = b.derive(fc, CTX, 14.0);
    assert_eq!(got, direct.to_string());
    assert!(direct.get("_derived").is_some());
    // NaN в часе — «разгар дня»
    let noon = b.derive(fc, CTX, f64::NAN);
    assert_eq!(noon, Value::Object(w.derive(&f, &c, f64::NAN)).to_string());
    assert_eq!(b.derive("not json", CTX, 14.0), "{}");

    let ds: Value = serde_json::from_str(&b.diurnal_state(25.0, 15.0, CTX)).unwrap();
    let d = w.diurnal_state(25.0, 15.0, &c);
    assert_eq!(ds["temperature_c"], d.temperature_c);
    assert_eq!(ds["sunset_h"], d.sunset_h);
    assert_eq!(ds["peak_h"], d.peak_h);

    let cell: Value = serde_json::from_str(&b.climate_cell(50.0, 86.0, 7, 15)).unwrap();
    let k = w.climate_at(50.0, 86.0, 7, 15);
    assert_eq!(cell["tx_c"], k.tx_c);
    assert_eq!(cell["z_cell_m"], k.z_cell_m);
    assert_eq!(cell["src"]["hh5"], k.src.hh5.as_str());

    let wj = Value::Object(w.derive(&f, &c, 14.0)).to_string();
    let t = b.temp_at_altitude(&wj, 2500.0, 7, 15);
    let m = serde_json::from_str::<Value>(&wj).unwrap();
    assert_eq!(t, w.temp_at_altitude(m.as_object().unwrap(), 2500.0, 7, 15));
    assert!(b.temp_at_altitude("{}", 2500.0, 7, 15).is_nan());

    let rc: Value = serde_json::from_str(&b.reference_context()).unwrap();
    let r = w.reference_context();
    assert_eq!(rc["month"], r.month);
}

#[test]
fn attach_weather_and_place_context() {
    let (b, _) = both();
    let mut air = Bridge::new(Box::new(dp_air::Formula::new()));
    assert_eq!(air.attach_weather(None), BAD_INPUT);
    assert!(!air.last_error().is_empty());
    assert_eq!(air.place_context(), "{}");
    assert_eq!(air.attach_weather(b.arc()), OK);
    assert_eq!(air.last_error(), "");
    // Calm: погоду принимает молча, контекста нет
    let mut calm = Bridge::new(Box::new(Calm::new()));
    assert_eq!(calm.attach_weather(b.arc()), OK);
    assert_eq!(calm.place_context(), "{}");
}

#[test]
fn place_context_after_load_place() {
    let (b, _) = both();
    let mut air = Bridge::new(Box::new(dp_air::Formula::new()));
    assert_eq!(air.configure(&["wind".into(), "{}".into()], 1), OK);
    assert_eq!(air.attach_weather(b.arc()), OK);
    let header = r#"{"version":1,"loc":{"id":"t","center_lat":50.0,"center_lon":86.0,
"utc_offset_h":7.0,"month":7,"day":1},"grid":{"origin_x":-100,"origin_z":-100,"spacing":50,
"width":4,"height":4},"surface_classes":{"grass":1},"start_sites":[]}"#;
    let n = 16;
    assert_eq!(
        air.load_place(
            header,
            &vec![10.0; n],
            &vec![0; n],
            &vec![1; n],
            &vec![0.5; n]
        ),
        OK
    );
    let c: Value = serde_json::from_str(&air.place_context()).unwrap();
    for k in [
        "valley_msl_m",
        "mean_msl_m",
        "month",
        "day",
        "lat",
        "lon",
        "utc_offset_h",
    ] {
        assert!(c.get(k).is_some(), "{k}");
    }
    assert_eq!(c["lat"], 50.0);
    assert_eq!(c["month"], 7);
    assert_eq!(c["valley_msl_m"], 10.0);
}
