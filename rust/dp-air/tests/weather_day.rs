//! RW-12c: ход дня, коэффициенты и мягкая смена погоды (`dp_air::weather`) против дампа GDScript
//! (`tools/wind_fixtures/day_dump.sh`, данные — `tests/data/day_dump/`) и тест
//! `tests/atmosphere/test_weather_day.gd` (часть про погоду), перенесённый в cargo.
//!
//! Допуск дампа: относительный 1e-9 (GD `float` = f64) плюс абсолютный 1e-12; строки и булевы точно,
//! набор ключей совпадает; `null` дампа (NaN и inf GD) — нечисло в Rust. Направления на солнце (`Vector3`
//! GD — f32) — абсолютный допуск 2e-7 (ошибка округления f32 единичного вектора, ~1.2e-7 на компоненту).
use dp_air::field::weather_core::{WeatherConfigs, WeatherModelCfg};
use dp_air::weather::{
    AtmoDay, Coefficients, WeatherMap, WeatherState, WorldTime, climate_place, derive,
    wind_conditions,
};
use dp_air::{Configs, Forecast};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

const REL: f64 = 1e-9;
const ABS: f64 = 1e-12;
const SUN_ABS: f64 = 2e-7;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn read_cfg(n: &str) -> String {
    std::fs::read_to_string(root().join("configs").join(format!("{n}.json"))).unwrap()
}

fn wm() -> &'static WeatherModelCfg {
    static C: OnceLock<WeatherConfigs> = OnceLock::new();
    &C.get_or_init(|| {
        let files = ["atmosphere", "weather_model", "surface_heat"]
            .iter()
            .map(|n| (n.to_string(), read_cfg(n)))
            .collect();
        WeatherConfigs::from_configs(&Configs::new(files)).unwrap()
    })
    .wm
}

fn atm() -> &'static Value {
    static A: OnceLock<Value> = OnceLock::new();
    A.get_or_init(|| serde_json::from_str(&read_cfg("atmosphere")).unwrap())
}

fn rows() -> &'static Vec<Value> {
    static R: OnceLock<Vec<Value>> = OnceLock::new();
    R.get_or_init(|| {
        let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/day_dump/rows.jsonl.zst");
        let raw = zstd::decode_all(&std::fs::read(&p).unwrap_or_else(|e| panic!("{p:?}: {e}"))[..])
            .unwrap();
        String::from_utf8(raw)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    })
}

fn kind_rows(kind: &str) -> impl Iterator<Item = &'static Value> + '_ {
    rows().iter().filter(move |r| r["kind"] == kind)
}

fn f(v: &Value) -> f64 {
    v.as_f64().unwrap_or(f64::NAN)
}

/// Сравнение дерева json; `None` — совпало, иначе описание первого расхождения.
fn diff(path: &str, got: &Value, want: &Value) -> Option<String> {
    match (got, want) {
        (_, Value::Null) => match got {
            Value::Null => None,
            Value::Number(n) if !n.as_f64().unwrap().is_finite() => None,
            _ => Some(format!("{path}: got {got}, want null (нечисло)")),
        },
        (Value::Number(a), Value::Number(b)) => {
            let (a, b) = (a.as_f64().unwrap(), b.as_f64().unwrap());
            ((a - b).abs() > REL * b.abs() + ABS).then(|| format!("{path}: got {a}, want {b}"))
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
                .find_map(|(k, wv)| diff(&format!("{path}.{k}"), &a[k], wv))
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

fn expect_same(what: &str, got: &Value, want: &Value) {
    if let Some(d) = diff(what, got, want) {
        panic!("{d}");
    }
}

fn wmap(v: &Value) -> WeatherMap {
    v.as_object().cloned().unwrap_or_default()
}

fn world_time(row: &Value) -> WorldTime {
    let w = &row["world_time"];
    // дамп хранит `time` из world.json; нет — запасные значения GD
    WorldTime::from_world(&serde_json::json!({ "time": w }))
}

/// Источник из дампа: `day_dump.gd` → `test_source`.
fn test_source(x: f64, z: f64, h: f64) -> f64 {
    0.5 + 0.0004 * x - 0.0003 * z + 0.03 * (h - 12.0)
}

/// День строки дампа (`day`/`day_state`) тем же путём, что `Atmosphere._f_resolve`.
fn day_of(row: &Value) -> AtmoDay {
    let c = &row["ctx"];
    let g = |k: &str, def: f64| c.get(k).map_or(def, f);
    let ctx = dp_air::weather::PlaceCtx {
        month: f(&c["month"]) as i64,
        day: f(&c["day"]) as i64,
        lat: f(&c["lat"]),
        lon: f(&c["lon"]),
        utc_offset_h: g("utc_offset_h", f64::NAN),
        valley_msl_m: g("valley_msl_m", f64::NAN),
        mean_msl_m: g("mean_msl_m", 0.0),
        start_msl_m: f64::NAN,
    };
    let cell = row.get("cell").cloned().unwrap_or_else(|| {
        // day_state: ячейки нет — берём из соседней строки того же места
        kind_rows("day")
            .find(|r| r["place"] == row["place"])
            .unwrap()["cell"]
            .clone()
    });
    let cp = climate_place(&cell, &ctx, wm());
    let fc: Forecast = serde_json::from_value(row["forecast"].clone()).unwrap();
    let tm = &row["timing"];
    let wt = if row.get("world_time").is_some() {
        world_time(row)
    } else {
        world_time(kind_rows("day").next().unwrap())
    };
    AtmoDay::from_forecast(
        fc,
        ctx,
        cp,
        wm().clone(),
        wmap(&row["overrides"]),
        f(&tm["start_hour"]),
        f(&tm["t0"]),
        f(&tm["speed"]),
        f(&tm["quantum_h"]),
        wt,
    )
    .with_source_fn(Box::new(test_source))
}

fn arr3(v: &Value) -> [f64; 3] {
    let a = v.as_array().unwrap();
    [f(&a[0]), f(&a[1]), f(&a[2])]
}

fn json_f(x: f64) -> Value {
    serde_json::Number::from_f64(x).map_or(Value::Null, Value::Number)
}

const VALUE_KEYS: [&str; 8] = [
    "background_sink_ms",
    "convective_turbulence_ms",
    "mech_turbulence_k",
    "thermal_edge_k",
    "cloudbase_agl_m",
    "cirrus_cover",
    "sky_cover",
    "no_such_key",
];

// ---------------------------------------------------------------- дамп

#[test]
fn dump_has_expected_kinds() {
    assert!(rows().len() >= 100, "строк {}", rows().len());
    assert_eq!(kind_rows("day").count(), 48);
    assert!(kind_rows("day_state").count() >= 12);
    assert!(kind_rows("coeffs").count() >= 40);
    assert!(kind_rows("blend").count() >= 10);
    let times: usize = kind_rows("day")
        .map(|r| r["samples"].as_array().unwrap().len())
        .sum();
    assert!(times >= 600, "точек t {times}");
}

// ---------------------------------------------------------------- AtmoDay

#[test]
fn hour_step_and_fraction_match_dump() {
    let mut n = 0;
    for r in kind_rows("day") {
        let mut d = day_of(r);
        for s in r["samples"].as_array().unwrap() {
            let t = f(&s["t"]);
            let tag = format!("{} t={t}", r["place"]);
            assert!((d.hour_at(t) - f(&s["hour"])).abs() <= 1e-12, "{tag}: hour");
            assert_eq!(d.step_index(t), f(&s["q"]) as i64, "{tag}: q");
            let (_, _, fr) = d.bracket(t);
            assert!(
                (fr - f(&s["f"])).abs() <= 1e-12,
                "{tag}: f {fr} против {}",
                s["f"]
            );
            n += 1;
        }
    }
    assert!(n >= 600);
}

#[test]
fn hour_is_clamped_to_world_time() {
    // min_hour 6, max_hour из world.json дампа; до старта время не идёт назад за min, после — стоит
    let r = kind_rows("day")
        .find(|r| r["timing"]["start_hour"] == 19.5)
        .unwrap();
    let d = day_of(r);
    let wt = world_time(r);
    assert!((d.hour_at(f64::MAX / 1e300) - wt.max_hour).abs() < 1e-12);
    assert_eq!(d.hour_at(-1e9), wt.min_hour);
    let r5 = kind_rows("day")
        .find(|r| r["timing"]["start_hour"] == 5.0)
        .unwrap();
    assert_eq!(
        day_of(r5).hour_at(f(&r5["timing"]["t0"])),
        wt.min_hour,
        "старт 5 ч зажат в min_hour"
    );
    // без world — запасные 6…20 (GD AtmoDay._init)
    assert_eq!(WorldTime::from_world(&Value::Null), WorldTime::default());
    assert_eq!(WorldTime::default().max_hour, 20.0);
}

#[test]
fn weather_at_matches_dump() {
    let mut n = 0;
    for r in kind_rows("day") {
        let mut d = day_of(r);
        for s in r["samples"].as_array().unwrap() {
            let w = d.weather_at(f(&s["t"]));
            expect_same(
                &format!("{} t={} weather", r["place"], s["t"]),
                &Value::Object((*w).clone()),
                &s["weather"],
            );
            n += 1;
        }
    }
    assert!(n >= 600);
}

#[test]
fn initial_weather_matches_dump() {
    for r in kind_rows("day") {
        let mut d = day_of(r);
        // дамп: derive_fn(start_hour); час места t0 даёт start_hour (если не зажат)
        let t0 = f(&r["timing"]["t0"]);
        let h = d.hour_at(t0);
        if (h - f(&r["timing"]["start_hour"])).abs() > 1e-12 {
            continue; // старт вне диапазона часов: initial = derive на start_hour без зажима
        }
        let q_start = (h / d.quantum_h).floor() * d.quantum_h;
        if (q_start - h).abs() > 1e-12 {
            continue;
        }
        let w = d.weather_at(t0);
        expect_same("initial", &Value::Object((*w).clone()), &r["initial"]);
    }
    // overrides: ключи поверх, сетка источников задана
    let r = kind_rows("day")
        .find(|r| r["overrides"].as_object().is_some_and(|o| !o.is_empty()))
        .unwrap();
    let w = day_of(r).weather_at(0.0);
    assert_eq!(w["thermal_spacing_m"], 777.0);
    assert_eq!(w["cloud_size_factor"], 1.3);
    assert!(!w.contains_key("static_thermals"));
}

#[test]
fn bracket_next_step_and_value_at_match_dump() {
    for r in kind_rows("day") {
        let mut d = day_of(r);
        for s in r["samples"].as_array().unwrap() {
            let t = f(&s["t"]);
            let (_, w1, _) = d.bracket(t);
            expect_same("w1", &Value::Object((*w1).clone()), &s["w1"]);
            for k in VALUE_KEYS {
                let v = d.value_at(t, k, 0.7);
                expect_same(
                    &format!("{} t={t} value_at({k})", r["place"]),
                    &json_f(v),
                    &s["value_at"][k],
                );
            }
        }
    }
}

#[test]
fn sun_at_matches_dump_f32() {
    let mut worst = 0.0f64;
    for r in kind_rows("day") {
        let d = day_of(r);
        for s in r["samples"].as_array().unwrap() {
            let got = d.sun_at(f(&s["t"]));
            let want = arr3(&s["sun"]);
            for i in 0..3 {
                let e = (got[i] as f64 - want[i]).abs();
                worst = worst.max(e);
                assert!(
                    e <= SUN_ABS,
                    "{} t={} sun[{i}]: {} против {}",
                    r["place"],
                    s["t"],
                    got[i],
                    want[i]
                );
            }
        }
    }
    eprintln!("sun_at: наибольшее расхождение с GD {worst:.3e}");
}

#[test]
fn source_at_matches_dump_and_clamps() {
    let pts = [[0.0, 0.0], [1500.0, -800.0], [-3000.0, 2500.0]];
    let mut clamped = [false; 2];
    for r in kind_rows("day") {
        let d = day_of(r);
        for s in r["samples"].as_array().unwrap() {
            for (i, p) in pts.iter().enumerate() {
                let v = d.source_at(p[0], p[1], f(&s["t"])).unwrap();
                expect_same("source", &json_f(v), &s["source"][i]);
                clamped[0] |= v == 0.0;
                clamped[1] |= v == 1.0;
            }
        }
    }
    assert!(
        clamped[0] && clamped[1],
        "тестовая сила должна упираться в 0 и в 1"
    );
    // без source_fn — «не задано»
    let none = AtmoDay::new(12.0, 0.0, 1.0, 1.0 / 60.0, WorldTime::default());
    assert_eq!(none.source_at(0.0, 0.0, 0.0), None);
    assert_eq!(none.sun_at(0.0), [0.0; 3]);
}

#[test]
fn day_without_weather_is_empty_and_rebase_moves_clock() {
    let mut d = AtmoDay::new(13.0, 0.0, 1.0, 60.0 / 3600.0, WorldTime::default());
    assert!(!d.has_weather());
    assert!(d.weather_at(0.0).is_empty());
    assert_eq!(d.value_at(10.0, "x", 4.5), 4.5);
    d.rebase(100.0, 8.0, 60.0);
    assert_eq!(d.hour_at(100.0), 8.0);
    assert!(
        (d.hour_at(160.0) - 9.0).abs() < 1e-12,
        "минута при speed 60 — час"
    );
}

#[test]
fn weather_cache_is_per_step_and_bounded() {
    let calls = Arc::new(Mutex::new(Vec::<f64>::new()));
    let c2 = calls.clone();
    let mut d = AtmoDay::new(
        6.0,
        0.0,
        3600.0,
        1.0,
        WorldTime {
            min_hour: 0.0,
            max_hour: 1e9,
            ..WorldTime::default()
        },
    )
    .with_weather_fn(Box::new(move |h| {
        c2.lock().unwrap().push(h);
        let mut m = Map::new();
        m.insert("a".into(), json_f(h));
        m
    }));
    for _ in 0..3 {
        d.weather_at(0.5);
        d.weather_at(0.9);
    }
    assert_eq!(calls.lock().unwrap().len(), 1, "один шаг — один расчёт");
    let (a, b, fr) = d.bracket(1.5 * 3600.0 / 3600.0); // час 7.5: шаги 7 и 8
    assert_eq!((a["a"].as_f64(), b["a"].as_f64()), (Some(7.0), Some(8.0)));
    assert!((fr - 0.5).abs() < 1e-12);
    // за 512 записей кеш очищается и считает заново, но результат тот же
    for k in 0..700 {
        d.weather_at(k as f64);
    }
    assert!(calls.lock().unwrap().len() >= 700);
    assert_eq!(d.weather_at(10.0)["a"].as_f64(), Some(16.0));
}

// ---------------------------------------------------------------- коэффициенты

fn atm_variant(variant: &str) -> Value {
    let mut a = atm().clone();
    if variant == "lee_defaults" {
        let lee = a["lee"].as_object_mut().unwrap();
        for k in [
            "shear_layer_m",
            "danger_min_wind_ms",
            "danger_full_wind_ms",
            "danger_sink_per_wind",
            "danger_turbulence_per_wind",
            "burst_per_wind",
            "burst_scale_m",
            "burst_threshold",
            "burst_width",
            "rotor_reverse",
            "rotor_height_fraction",
            "rotor_max_amplitude_ms",
            "heat_kill_wm2",
            "heat_sigma_per_wstar",
        ] {
            lee.remove(k);
        }
    }
    a
}

#[test]
fn coefficients_match_cache_coefficients() {
    let mut n = 0;
    for r in kind_rows("coeffs") {
        let a = atm_variant(r["variant"].as_str().unwrap());
        let w = wmap(&r["weather"]);
        let c = Coefficients::new(&a, &w);
        let tag = format!("{} {}", r["label"], r["variant"]);
        expect_same(
            &format!("{tag} coeffs"),
            &Value::Object(c.to_map()),
            &r["coeffs"],
        );
        n += 1;
    }
    assert!(n >= 40);
}

#[test]
fn insolation_wind_conditions_and_default_sun_match() {
    for r in kind_rows("coeffs").filter(|r| r["variant"] == "default") {
        let w = wmap(&r["weather"]);
        let s = WeatherState::new(atm(), w.clone());
        expect_same("insolation", &json_f(s.coeffs.insolation), &r["insolation"]);
        let (sun, cover) = wind_conditions(atm(), &w, wm());
        expect_same(
            "wind_conditions",
            &Value::Array(vec![json_f(sun), json_f(cover)]),
            &r["wind_conditions"],
        );
        assert_eq!(s.wind_conditions(wm()), (sun, cover));
        let st = s.sun_state(0.0);
        let want = arr3(&r["sun_dir"]);
        for i in 0..3 {
            assert!(
                (st[i] as f64 - want[i]).abs() <= SUN_ABS,
                "{}: sun_dir[{i}]",
                r["label"]
            );
        }
        assert_eq!(
            st[3] as f64,
            r["insolation"].as_f64().unwrap().clamp(0.0, 1.0) as f32 as f64
        );
    }
}

// ---------------------------------------------------------------- ход дня по шагам

#[test]
fn day_state_follows_apply_day() {
    let mut n_steps = 0;
    let mut n_updates = 0;
    for r in kind_rows("day_state") {
        let mut d = day_of(r);
        let mut s = WeatherState::new(atm(), wmap(&r["initial"]));
        assert_eq!(s.versions(), (1, 1));
        d = d.with_source_fn(Box::new(test_source));
        s.set_day(d);
        let tag = format!("{} fc={} timing={}", r["place"], r["forecast"], r["timing"]);
        let check = |s: &WeatherState, st: &Value, what: &str| {
            let c = &s.coeffs;
            for (k, v) in [
                ("bg_sink", c.bg_sink),
                ("conv_amp", c.conv_amp),
                ("mech_k", c.mech_k),
                ("edge", c.edge_factor),
                ("insolation", c.insolation),
                ("cloudbase_agl", c.cloudbase_agl),
            ] {
                expect_same(&format!("{tag} {what} {k}"), &json_f(v), &st[k]);
            }
            assert_eq!(
                s.version - 1,
                st["updates"].as_u64().unwrap(),
                "{tag} {what}: число обновлений"
            );
            if let Some(w) = st.get("weather") {
                expect_same(
                    &format!("{tag} {what} weather"),
                    &Value::Object(s.map.clone()),
                    w,
                );
            }
        };
        check(&s, &r["start"], "start");
        let mut t = 0.0;
        for (i, st) in r["steps"].as_array().unwrap().iter().enumerate() {
            t += [0.05, 0.3, 0.5, 1.0][i % 4];
            assert!((t - f(&st["t"])).abs() < 1e-9);
            s.advance_to(t);
            check(&s, st, &format!("step {i}"));
            n_steps += 1;
        }
        expect_same(
            &format!("{tag} end"),
            &Value::Object(s.map.clone()),
            &r["end_weather"],
        );
        n_updates += s.version - 1;
        assert_eq!(s.rebuild_version, 1, "ход дня не перестраивает");
    }
    assert!(n_steps >= 2400);
    assert!(
        n_updates >= 80,
        "в дампе шаги погоды должны меняться: {n_updates}"
    );
}

// ---------------------------------------------------------------- мягкая смена

#[test]
fn soft_blend_follows_update_weather() {
    let dts = [0.1, 1.0, 0.5, 2.0, 5.0];
    let mut finished = 0;
    for r in kind_rows("blend") {
        let from = wmap(&r["from"]);
        let mut s = WeatherState::new(atm(), from);
        let bs = f(&r["blend_s"]);
        let tag = format!("{} blend_s={bs}", r["label"]);
        expect_same(
            &format!("{tag} start"),
            &Value::Object(s.coeffs.to_map()),
            &{
                let mut m = r["start"].clone();
                m.as_object_mut().unwrap().remove("cloudbase_agl_extra");
                m
            },
        );
        s.update_weather(&wmap(&r["to"]), bs);
        let au = &r["after_update"];
        let cmp = |s: &WeatherState, st: &Value, what: &str| {
            let c = &s.coeffs;
            for (k, v) in [
                ("bg_sink", c.bg_sink),
                ("conv_amp", c.conv_amp),
                ("mech_k", c.mech_k),
                ("edge", c.edge_factor),
                ("insolation", c.insolation),
                ("cloudbase_agl", c.cloudbase_agl),
            ] {
                expect_same(&format!("{tag} {what} {k}"), &json_f(v), &st[k]);
            }
            assert_eq!(
                s.version - 1,
                st["updates"].as_u64().unwrap(),
                "{tag} {what}: обновления"
            );
        };
        cmp(&s, au, "after_update");
        assert_eq!(
            !s.blending(),
            au["target_empty"].as_bool().unwrap(),
            "{tag}: цель после update"
        );
        let mut t = 0.0;
        for (i, st) in r["steps"].as_array().unwrap().iter().enumerate() {
            let dt = dts[i % dts.len()];
            assert_eq!(dt, f(&st["dt"]));
            t += dt;
            s.advance_to(t);
            cmp(&s, st, &format!("step {i}"));
            assert_eq!(
                !s.blending(),
                st["target_empty"].as_bool().unwrap(),
                "{tag} step {i}: цель"
            );
        }
        expect_same(
            &format!("{tag} end"),
            &Value::Object(s.map.clone()),
            &r["end_weather"],
        );
        finished += usize::from(!s.blending());
    }
    assert!(finished >= 3, "часть смен должна дойти до цели: {finished}");
}

#[test]
fn blend_steps_compose_exactly() {
    // повторное lerp(1 − exp(−dt/τ)) складывается точно: шаг кадра результат не меняет
    let from = wmap(&serde_json::from_str::<Value>(&read_cfg("weather/weak")).unwrap());
    let to = wmap(&serde_json::from_str::<Value>(&read_cfg("weather/strong")).unwrap());
    let run = |dts: &[f64]| {
        let mut s = WeatherState::new(atm(), from.clone());
        s.update_weather(&to, 300.0);
        let mut t = 0.0;
        for dt in dts {
            t += dt;
            s.advance_to(t);
        }
        s.coeffs
    };
    let a = run(&[10.0; 10]);
    let b = run(&[0.5; 200]);
    let c = run(&[100.0]);
    for (x, y) in [
        (a.bg_sink, b.bg_sink),
        (a.conv_amp, c.conv_amp),
        (a.edge_factor, b.edge_factor),
        (a.cloudbase_agl, c.cloudbase_agl),
    ] {
        assert!((x - y).abs() < 1e-9 * y.abs().max(1.0), "{x} против {y}");
    }
    // нулевая blend_s — сразу цель, цель сброшена
    let mut s = WeatherState::new(atm(), from);
    s.update_weather(&to, 0.0);
    assert!(!s.blending());
    assert_eq!(s.coeffs.bg_sink, f(&to["background_sink_ms"]));
}

// ---------------------------------------------------------------- версии, json, солнце

#[test]
fn versions_grow_only_on_change() {
    let weak = wmap(&serde_json::from_str::<Value>(&read_cfg("weather/weak")).unwrap());
    let strong = wmap(&serde_json::from_str::<Value>(&read_cfg("weather/strong")).unwrap());
    let mut s = WeatherState::new(atm(), weak.clone());
    assert_eq!(s.versions(), (1, 1), "первая настройка — перестройка");
    for t in [0.1, 5.0, 100.0] {
        s.advance_to(t); // без дня и без цели
    }
    let json0 = s.weather_json();
    assert_eq!(s.versions(), (1, 1), "без смены версии стоят");
    s.update_weather(&strong, 60.0);
    assert_eq!(s.versions(), (2, 1), "мягкая смена: растёт только первая");
    for t in [101.0, 102.0] {
        s.advance_to(t); // шаги смеси версию не двигают
    }
    assert_eq!(s.versions(), (2, 1));
    assert_ne!(s.weather_json(), json0, "после смены json другой");
    s.rebuild(strong.clone());
    assert_eq!(s.versions(), (3, 2), "перестройка: растут обе");
    assert!(!s.blending());
    assert_eq!(s.coeffs.bg_sink, f(&strong["background_sink_ms"]));
}

#[test]
fn weather_json_round_trips() {
    let r = kind_rows("coeffs")
        .find(|r| r["label"] == "weather/wave")
        .unwrap();
    let s = WeatherState::new(atm(), wmap(&r["weather"]));
    let back: Value = serde_json::from_str(&s.weather_json()).unwrap();
    expect_same("json", &back, &r["weather"]);
}

#[test]
fn day_keeps_wind_and_spacing_and_bumps_version_per_step() {
    // test_weather_day.gd::test_soft_update_keeps_thermals (погодная часть): сетка источников и ветер
    // не меняются при смене погоды, кромка плавно идёт к новой за blend_s
    let r = kind_rows("day")
        .find(|r| r["timing"]["speed"] == 1.0 && r["place"] == "ongudai")
        .unwrap();
    let mut d10 = day_of(r);
    let w10 = (*d10.weather_at(-1e9)).clone(); // зажат в min_hour
    let mut s = WeatherState::new(atm(), w10);
    let spacing = f(&s.map["thermal_spacing_m"]);
    let wind = f(&s.map["wind_speed_kmh"]);
    let cb0 = s.coeffs.cloudbase_agl;
    let mut d14 = day_of(r);
    d14.rebase(0.0, 14.0, 1.0);
    let target = (*d14.weather_at(0.0)).clone();
    let goal = f(&target["cloudbase_agl_m"]);
    s.update_weather(&target, 300.0);
    s.advance_to(1.0);
    assert!(
        (s.coeffs.cloudbase_agl - cb0).abs() < (goal - cb0).abs() * 0.1 + 1e-9,
        "кромка не прыгает сразу"
    );
    for i in 2..=901 {
        s.advance_to(i as f64);
    }
    assert!(
        (s.coeffs.cloudbase_agl - goal).abs() < 25.0,
        "через 15 мин кромка на месте: {} против {goal}",
        s.coeffs.cloudbase_agl
    );
    assert_eq!(f(&s.map["thermal_spacing_m"]), spacing);
    assert_eq!(f(&s.map["wind_speed_kmh"]), wind);
}

#[test]
fn wind_conditions_follow_hour() {
    // test_weather_day.gd::test_wind_profile_follows_hour (условия профиля): вечером солнце ниже,
    // облачность — прогноза
    let r = kind_rows("day")
        .find(|r| r["timing"]["speed"] == 1.0 && r["place"] == "ongudai")
        .unwrap();
    let mut d = day_of(r);
    d.rebase(0.0, 12.0, 1.0);
    let w12 = (*d.weather_at(0.0)).clone();
    d.rebase(0.0, 20.0, 1.0);
    let w20 = (*d.weather_at(0.0)).clone();
    let (e12, c12) = wind_conditions(atm(), &w12, wm());
    let (e20, c20) = wind_conditions(atm(), &w20, wm());
    assert!(e20 < e12, "вечером солнце ниже: {e20} < {e12}");
    assert_eq!(c12, c20);
    assert_eq!(c12, wm().sky_params("scattered").0);
    // пресет без _derived: высота солнца из clouds, облачность 0
    let preset = wmap(&serde_json::from_str::<Value>(&read_cfg("weather/medium")).unwrap());
    let (e, c) = wind_conditions(atm(), &preset, wm());
    assert_eq!(e, atm()["clouds"]["sun_elevation_deg"].as_f64().unwrap());
    assert_eq!(c, 0.0);
}

#[test]
fn sun_state_priorities() {
    let r = kind_rows("day").find(|r| r["place"] == "ongudai").unwrap();
    let d = day_of(r);
    let sun_t = d.sun_at(0.0);
    let medium = wmap(&serde_json::from_str::<Value>(&read_cfg("weather/medium")).unwrap());
    let mut s = WeatherState::new(atm(), medium);
    let def = s.sun_state(0.0);
    s.set_day(d);
    let from_day = s.sun_state(0.0);
    assert_eq!(&from_day[..3], &sun_t[..]);
    s.set_sun_direction(Some([0.0, 2.0, 0.0]));
    let set = s.sun_state(0.0);
    assert_eq!(&set[..3], &[0.0, 1.0, 0.0], "заданное нормализуется");
    s.set_sun_direction(Some([f32::NAN, 0.0, 0.0]));
    s.set_sun_direction(Some([0.0; 3]));
    assert_eq!(
        &s.sun_state(0.0)[..3],
        &[0.0, 1.0, 0.0],
        "нечисло и нуль игнорируются"
    );
    s.set_sun_direction(None);
    assert_eq!(&s.sun_state(0.0)[..3], &from_day[..3]);
    assert!(def[1] > 0.0 && (0.0..=1.0).contains(&def[3]));
}

#[test]
fn derive_through_day_equals_direct_derive() {
    // день без overrides на кванте = derive на часе кванта, кроме сетки источников разгара дня
    let r = kind_rows("day")
        .find(|r| {
            r["overrides"].as_object().is_some_and(Map::is_empty) && r["timing"]["speed"] == 1.0
        })
        .unwrap();
    let mut d = day_of(r);
    let c = &r["ctx"];
    let ctx = dp_air::weather::PlaceCtx {
        month: f(&c["month"]) as i64,
        day: f(&c["day"]) as i64,
        lat: f(&c["lat"]),
        lon: f(&c["lon"]),
        utc_offset_h: c.get("utc_offset_h").map_or(f64::NAN, f),
        valley_msl_m: c.get("valley_msl_m").map_or(f64::NAN, f),
        mean_msl_m: c.get("mean_msl_m").map_or(0.0, f),
        start_msl_m: f64::NAN,
    };
    let cp = climate_place(&r["cell"], &ctx, wm());
    let fc: Forecast = serde_json::from_value(r["forecast"].clone()).unwrap();
    let t = 3600.0;
    let q = d.step_index(t);
    let mut want = derive(&fc, &ctx, q as f64 * d.quantum_h, &cp, wm());
    want.remove("static_thermals");
    let got = d.weather_at(t);
    for (k, v) in &want {
        if k != "thermal_spacing_m" {
            expect_same(k, &got[k], v);
        }
    }
}
