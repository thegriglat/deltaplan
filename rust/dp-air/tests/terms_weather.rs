//! RW-12d: погода в `Terms` (прогноз → derive по ходу дня, `WeatherState`, версии, рамка ветра) против
//! эталона GDScript `cases/ongudai_day_*.weather.json` (W8 v2; допуск `1e-6 + 1e-5·|ref|`) и проверки
//! поведения: зажим часов, версии, пресет без дня, мягкая смена, `sun_state`.
use dp_air::field::weather_core::WeatherModelCfg;
use dp_air::fixtures::{read_case, read_place};
use dp_air::terms::{PlaceLink, Terms};
use dp_air::weather::{climate_place, derive};
use dp_air::{Conditions, Configs};
use serde_json::{Value, json};
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

fn wdir() -> PathBuf {
    root().join("tests/fixtures/wind")
}

fn terms_with(place: &str) -> (Terms, dp_air::Place) {
    let p = read_place(&wdir().join(format!("places/{place}.json"))).unwrap();
    let mut t = Terms::default();
    t.configure(&configs(), 1);
    t.set_place(Some(&p));
    (t, p)
}

const REL: f64 = 1e-5;
const ABS: f64 = 1e-6;

fn diff(path: &str, got: &Value, want: &Value) -> Option<String> {
    match (got, want) {
        (Value::Null, Value::Null) => None,
        (Value::Number(n), Value::Null) if !n.as_f64().unwrap().is_finite() => None,
        (Value::Number(a), Value::Number(b)) => {
            let (a, b) = (a.as_f64().unwrap(), b.as_f64().unwrap());
            ((a - b).abs() > ABS + REL * b.abs()).then(|| format!("{path}: got {a}, want {b}"))
        }
        (Value::Object(a), Value::Object(b)) => {
            let mut ka: Vec<_> = a.keys().collect();
            let mut kb: Vec<_> = b.keys().collect();
            ka.sort();
            kb.sort();
            if ka != kb {
                return Some(format!("{path}: ключи got {ka:?}, want {kb:?}"));
            }
            b.iter()
                .find_map(|(k, w)| diff(&format!("{path}.{k}"), &a[k], w))
        }
        (Value::Array(a), Value::Array(b)) => {
            if a.len() != b.len() {
                return Some(format!("{path}: длина {} против {}", a.len(), b.len()));
            }
            a.iter()
                .zip(b)
                .enumerate()
                .find_map(|(i, (x, y))| diff(&format!("{path}[{i}]"), x, y))
        }
        _ => (got != want).then(|| format!("{path}: got {got}, want {want}")),
    }
}

fn same(what: &str, got: &Value, want: &Value) {
    if let Some(d) = diff(what, got, want) {
        panic!("{d}");
    }
}

fn num(v: f64) -> Value {
    serde_json::Number::from_f64(v).map_or(Value::Null, Value::Number)
}

fn check_case(name: &str) {
    let case_path = wdir().join(format!("cases/{name}.json"));
    let case = read_case(&case_path).unwrap();
    let reference: Value = serde_json::from_str(
        &std::fs::read_to_string(wdir().join(format!("cases/{name}.weather.json"))).unwrap(),
    )
    .unwrap();
    let (mut t, place) = terms_with(&case.place);
    t.set_conditions(&case.conditions);

    // derive в разгар дня (по месту и ячейке климата заголовка)
    let cfg = configs();
    let wm = WeatherModelCfg::from_value(
        &serde_json::from_str(
            &cfg.files
                .iter()
                .find(|(n, _)| n == "weather_model")
                .unwrap()
                .1,
        )
        .unwrap(),
    );
    let pl = PlaceLink::of(&place);
    let climate = climate_place(&pl.cell, &pl.ctx, &wm);
    let fc = match &case.conditions.source {
        dp_air::Source::Forecast { forecast, .. } => forecast.clone(),
        _ => panic!("прогноз"),
    };
    let d = Value::Object(derive(&fc, &pl.ctx, f64::NAN, &climate, &wm));
    same("derive", &d, &reference["derive"]);

    let days = reference["day"].as_object().unwrap();
    assert_eq!(days.len(), case.times_s.len(), "{name}: моментов");
    for e in days.values() {
        let tm = e["t"].as_f64().unwrap();
        t.advance(tm);
        let w: Value = serde_json::from_str(&t.weather_json()).unwrap();
        same(&format!("{name} t={tm} weather"), &w, &e["weather"]);
        let c = t.coefficients().unwrap();
        for (k, got) in [
            ("bg_sink", c.bg_sink),
            ("conv_amp", c.conv_amp),
            ("mech_k", c.mech_k),
            ("edge_factor", c.edge_factor),
            ("cloudbase_agl", c.cloudbase_agl),
        ] {
            same(&format!("{name} t={tm} {k}"), &num(got), &e[k]);
        }
        same(
            &format!("{name} t={tm} insolation"),
            &num(c.insolation),
            &e["field_insolation"],
        );
        // sun_state: направление на солнце хода дня и get_insolation
        let s = t.sun_state(tm);
        let want_sun = json!([
            e["sun_at"][0],
            e["sun_at"][1],
            e["sun_at"][2],
            e["get_insolation"]
        ]);
        same(
            &format!("{name} t={tm} sun_state"),
            &json!(s.iter().map(|v| *v as f64).collect::<Vec<_>>()),
            &want_sun,
        );
        // рамка ветра: условия профиля (высота солнца часа, облачность) от выведенной погоды
        let mut w2 = t.wind.clone();
        w2.set_conditions(
            e["wind_conditions"][0].as_f64().unwrap(),
            e["wind_conditions"][1].as_f64().unwrap(),
        );
        assert_eq!(
            t.wind.profile_params(),
            w2.profile_params(),
            "{name} t={tm} профиль ветра"
        );
    }
}

#[test]
fn day_1_matches_reference() {
    check_case("ongudai_day_1");
}

#[test]
fn day_2_matches_reference() {
    check_case("ongudai_day_2");
}

#[test]
fn day_3_matches_reference() {
    check_case("ongudai_day_3");
}

fn forecast_cond(start_hour: f64, speed: f64, quantum_h: f64) -> Conditions {
    Conditions::from_json(
        &json!({
            "forecast": {"temperature_c": 24.0, "wind_speed_kmh": 12.0, "wind_from_deg": 151.0, "sky": "clear"},
            "start_hour": start_hour, "speed": speed, "quantum_h": quantum_h,
        })
        .to_string(),
    )
    .unwrap()
}

#[test]
fn hours_are_clamped_and_version_follows_changes() {
    let (mut t, _) = terms_with("ongudai");
    // 1 с = 1 час места; квант 0,5 ч
    t.set_conditions(&forecast_cond(19.0, 3600.0, 0.5));
    let v0 = t.weather_version();
    assert_eq!(v0.1, 1, "перестройка одна");
    // внутри кванта: погода шага та же, версия стоит (0,1 с — тот же шаг)
    t.advance(0.1);
    assert_eq!(t.weather_version(), v0);
    // час 19 -> 19,5: другой квант
    assert!(t.advance(0.6));
    let v1 = t.weather_version();
    assert!(v1.0 > v0.0 && v1.1 == v0.1, "{v0:?} {v1:?}");
    // зажим: максимум часа 21 (world.json); дальше время стоит, версия не растёт
    t.advance(2.5);
    let v2 = t.weather_version();
    t.advance(10.0);
    t.advance(50.0);
    assert_eq!(t.weather_version(), v2);
    assert_eq!(t.day().unwrap().hour_at(50.0), 21.0);
    // до min_hour тоже зажато
    t.set_conditions(&forecast_cond(3.0, 1.0, 0.5));
    assert_eq!(t.day().unwrap().hour_at(50.0), 6.0);
}

#[test]
fn preset_has_no_day_and_keeps_its_map() {
    let (mut t, _) = terms_with("ongudai");
    let c = Conditions::from_json(
        &json!({"preset": "weather/medium", "start_hour": 12.0, "speed": 1.0}).to_string(),
    )
    .unwrap();
    t.set_conditions(&c);
    assert!(t.day().is_none());
    let want: Value = serde_json::from_str(
        &configs()
            .files
            .iter()
            .find(|(n, _)| n == "weather/medium")
            .unwrap()
            .1,
    )
    .unwrap();
    let mut want = want;
    want.as_object_mut().unwrap().remove("static_thermals");
    let got: Value = serde_json::from_str(&t.weather_json()).unwrap();
    assert_eq!(got, want);
    let v = t.weather_version();
    t.advance(5.0);
    t.advance(500.0);
    assert_eq!(t.weather_version(), v, "эталон без дня стоит");
    // ветер из пресета, высота не зависит от старта
    assert!(t.wind.speed_ref > 0.0 && t.wind.ref_msl.is_nan());
}

#[test]
fn preset_switch_blends_softly_over_blend_s() {
    let (mut t, _) = terms_with("ongudai");
    let mk = |n: &str, b: Option<f64>| {
        Conditions::from_json(
            &json!({"preset": n, "start_hour": 12.0, "speed": 1.0, "blend_s": b}).to_string(),
        )
        .unwrap()
    };
    t.set_conditions(&mk("weather/weak", None));
    let (v0, r0) = t.weather_version();
    let bg0 = t.coefficients().unwrap().bg_sink;
    t.set_conditions(&mk("weather/strong", Some(60.0)));
    let (v1, r1) = t.weather_version();
    assert!(
        v1 > v0 && r1 == r0,
        "мягкая смена: версия растёт, перестройки нет"
    );
    let target = {
        let m: Value = serde_json::from_str(&t.weather_json()).unwrap();
        m["background_sink_ms"].as_f64().unwrap()
    };
    assert!((target - bg0).abs() > 1e-3, "пресеты различаются");
    // τ = blend_s/3 = 20 с: точная экспонента, шаги складываются
    t.advance(20.0);
    let got = t.coefficients().unwrap().bg_sink;
    let want = bg0 + (target - bg0) * (1.0 - (-1.0f64).exp());
    assert!((got - want).abs() < 1e-9, "{got} {want}");
    t.advance(1000.0);
    assert!((t.coefficients().unwrap().bg_sink - target).abs() < 1e-3);
    // перестройка (rebuild) растит вторую версию
    let mut c = mk("weather/medium", None);
    c.rebuild = true;
    t.set_conditions(&c);
    assert_eq!(t.weather_version().1, r1 + 1);
}

#[test]
fn sun_state_follows_day_and_external_direction() {
    let (mut t, _) = terms_with("ongudai");
    t.set_conditions(&forecast_cond(12.0, 1.0, 0.1));
    let s = t.sun_state(0.0);
    assert!(s[1] > 0.5, "в полдень июля солнце высоко: {s:?}");
    assert!((0.0..=1.0).contains(&s[3]));
    let n = (s[0] * s[0] + s[1] * s[1] + s[2] * s[2]).sqrt();
    assert!((n - 1.0).abs() < 1e-5);
    // направление, заданное снаружи, приоритетнее и нормализуется
    t.sun = Some([0.0, 2.0, 0.0]);
    assert_eq!(&t.sun_state(0.0)[..3], &[0.0, 1.0, 0.0]);
    // позже в тот же день солнце иначе
    t.sun = None;
    let late = t.sun_state(3.0 * 3600.0);
    assert_ne!(&late[..3], &s[..3]);
}

#[test]
fn forecast_without_place_falls_back_to_plain_map() {
    let mut t = Terms::default();
    t.configure(&configs(), 1);
    t.set_conditions(&forecast_cond(12.0, 1.0, 0.1));
    assert!(t.day().is_none());
    let m: Value = serde_json::from_str(&t.weather_json()).unwrap();
    assert_eq!(m["wind_speed_kmh"], json!(12.0));
    assert_eq!(m["sky"], json!("clear"));
    // место пришло позже: перестройка с выводом по часу
    let p = read_place(&wdir().join("places/synthetic.json")).unwrap();
    let before = t.weather_version();
    t.set_place(Some(&p));
    assert!(t.day().is_some());
    assert_eq!(t.weather_version().1, before.1 + 1);
    let m: Value = serde_json::from_str(&t.weather_json()).unwrap();
    assert!(m.get("_derived").is_some());
}
