//! RW-12b: погода из прогноза (`dp_air::weather`) против дампа GDScript
//! (`tools/wind_fixtures/weather_dump.sh`, данные — `tests/data/weather_dump/`) и тесты
//! `tests/atmosphere/test_weather_model.gd`, перенесённые в cargo.
//!
//! Допуск дампа: относительный 1e-9 (GD `float` = f64) плюс абсолютный 1e-12; строки и булевы
//! точно, набор ключей совпадает; `null` дампа (NaN и inf GD) — нечисло в Rust.
use dp_air::field::weather_core::{WeatherConfigs, WeatherModelCfg};
use dp_air::weather::{
    ClimatePlace, PlaceCtx, cirrus_base_cover, climate_place, derive, haze_k_rh, splitmix64,
    sun_block_cover, td_day, td_noise,
};
use dp_air::{Configs, Forecast};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

const REL: f64 = 1e-9;
const ABS: f64 = 1e-12;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn cfg() -> &'static WeatherModelCfg {
    static C: OnceLock<WeatherConfigs> = OnceLock::new();
    &C.get_or_init(|| {
        let r = root().join("configs");
        let files = ["atmosphere", "weather_model", "surface_heat"]
            .iter()
            .map(|n| {
                (
                    n.to_string(),
                    std::fs::read_to_string(r.join(format!("{n}.json"))).unwrap(),
                )
            })
            .collect();
        WeatherConfigs::from_configs(&Configs::new(files)).unwrap()
    })
    .wm
}

fn rows() -> &'static Vec<Value> {
    static R: OnceLock<Vec<Value>> = OnceLock::new();
    R.get_or_init(|| {
        let p =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/weather_dump/rows.jsonl.zst");
        let raw = zstd::decode_all(&std::fs::read(&p).unwrap_or_else(|e| panic!("{p:?}: {e}"))[..])
            .unwrap();
        String::from_utf8(raw)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    })
}

fn f(v: &Value) -> f64 {
    v.as_f64().unwrap_or(f64::NAN)
}

fn ctx_of(v: &Value, with_start: bool) -> PlaceCtx {
    let g = |k: &str, def: f64| v.get(k).map_or(def, f);
    PlaceCtx {
        month: f(&v["month"]) as i64,
        day: f(&v["day"]) as i64,
        lat: f(&v["lat"]),
        lon: f(&v["lon"]),
        utc_offset_h: g("utc_offset_h", f64::NAN),
        valley_msl_m: g("valley_msl_m", f64::NAN),
        mean_msl_m: g("mean_msl_m", 0.0),
        start_msl_m: if with_start {
            g("start_msl_m", f64::NAN)
        } else {
            f64::NAN
        },
    }
}

fn row_ctx(row: &Value, with_start: bool) -> PlaceCtx {
    let mut c = ctx_of(&row["ctx"], false);
    if with_start {
        c.start_msl_m = row.get("start_msl_m").map_or(f64::NAN, f);
    }
    c
}

fn place_json(p: &ClimatePlace) -> Value {
    let mut m = Map::new();
    for (k, v) in [
        ("td_c", p.td_c),
        ("td_sd_k", p.td_sd_k),
        ("z_cell_m", p.z_cell_m),
        ("t700_c", p.t700_c),
        ("z700_m", p.z700_m),
        ("tx_c", p.tx_c),
        ("dtr_k", p.dtr_k),
        ("wr", p.wr),
        ("trop_m", p.trop_m),
        ("hcc", p.hcc),
        ("gain_per_km", p.gain_per_km),
    ] {
        m.insert(
            k.into(),
            serde_json::Number::from_f64(v).map_or(Value::Null, Value::Number),
        );
    }
    m.insert(
        "src".into(),
        serde_json::json!({"hh1": p.src.hh1, "hh2": p.src.hh2, "hh5": p.src.hh5, "hh6": p.src.hh6}),
    );
    Value::Object(m)
}

/// Сравнение дерева json; пустая строка — совпало, иначе описание первого расхождения.
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
            let ka: Vec<_> = a.keys().collect();
            let kb: Vec<_> = b.keys().collect();
            if ka != kb {
                let mut ka = ka;
                let mut kb = kb;
                ka.sort();
                kb.sort();
                if ka != kb {
                    return Some(format!("{path}: ключи got {ka:?}, want {kb:?}"));
                }
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

fn forecast_of(v: &Value) -> Forecast {
    serde_json::from_value(v.clone()).unwrap()
}

fn kind_rows(kind: &str) -> impl Iterator<Item = &'static Value> + '_ {
    rows().iter().filter(move |r| r["kind"] == kind)
}

/// Все строки `derive` (опционально одного места / часа) против дампа.
fn check_derive(pred: impl Fn(&Value) -> bool) -> usize {
    let mut n = 0;
    for r in kind_rows("derive").filter(|r| pred(r)) {
        let ctx = row_ctx(r, false);
        let cp = climate_place(&r["cell"], &ctx, cfg());
        let hour = f(&r["hour"]);
        let w = derive(&forecast_of(&r["forecast"]), &ctx, hour, &cp, cfg());
        if let Some(d) = diff("weather", &Value::Object(w), &r["weather"]) {
            panic!(
                "{} {} h{} {}: {d}",
                r["place"], r["ctx"]["month"], r["hour"], r["forecast"]
            );
        }
        n += 1;
    }
    n
}

// ---------------------------------------------------------------- дамп

#[test]
fn dump_has_expected_size_and_kinds() {
    let n = rows().len();
    assert!(n >= 5000, "строк {n}");
    assert!(kind_rows("derive").count() >= 5000);
    assert_eq!(kind_rows("reference").count(), 4);
    assert!(kind_rows("place_nan_valley").count() >= 15);
    let places: std::collections::BTreeSet<_> = rows()
        .iter()
        .map(|r| r["place"].as_str().unwrap_or(""))
        .collect();
    for p in [
        "ongudai",
        "training_island",
        "volcano_island",
        "synthetic",
        "ongudai_no_hh1",
        "ongudai_no_hh6",
    ] {
        assert!(places.contains(p), "нет места {p}");
    }
}

#[test]
fn dump_climate_place_without_start() {
    for r in rows() {
        let ctx = row_ctx(r, false);
        let p = climate_place(&r["cell"], &ctx, cfg());
        if let Some(d) = diff("place", &place_json(&p), &r["place_nostart"]) {
            panic!("{} {}: {d}", r["place"], r["ctx"]);
        }
    }
}

#[test]
fn dump_climate_place_with_start() {
    let mut n = 0;
    for r in kind_rows("derive").chain(kind_rows("place_nan_valley")) {
        let ctx = row_ctx(r, true);
        let p = climate_place(&r["cell"], &ctx, cfg());
        if let Some(d) = diff("place", &place_json(&p), &r["place_start"]) {
            panic!("{} {}: {d}", r["place"], r["ctx"]);
        }
        n += 1;
    }
    assert!(n > 5000);
}

#[test]
fn dump_climate_place_valley_nan_means_no_correction() {
    for r in kind_rows("place_nan_valley") {
        assert!(r["ctx"]["valley_msl_m"].is_null());
        let cp = climate_place(&r["cell"], &row_ctx(r, false), cfg());
        let cell_tx = f(&r["cell"]["tx_c"]);
        assert!((cp.tx_c - cell_tx).abs() < 1e-12, "tx без valley = ячейка");
        assert!((cp.td_c - f(&r["cell"]["td_c"])).abs() < 1e-12);
    }
}

#[test]
fn dump_climate_flags_cover_all_branches() {
    let mut seen = std::collections::BTreeSet::new();
    for r in kind_rows("derive") {
        let s = &r["place_nostart"]["src"];
        seen.insert(format!("{}{}{}{}", s["hh1"], s["hh2"], s["hh5"], s["hh6"]));
    }
    assert!(seen.len() >= 3, "наборов сеток {seen:?}");
    assert!(
        seen.iter().any(|s| s.matches("none").count() == 4),
        "место без сеток"
    );
}

#[test]
fn dump_derive_ongudai() {
    assert!(check_derive(|r| r["place"] == "ongudai") > 1000);
}

#[test]
fn dump_derive_training_island() {
    assert!(check_derive(|r| r["place"] == "training_island") > 1000);
}

#[test]
fn dump_derive_volcano_island_southern() {
    assert!(check_derive(|r| r["place"] == "volcano_island") > 1000);
}

#[test]
fn dump_derive_synthetic_without_grids() {
    assert!(check_derive(|r| r["place"] == "synthetic") > 1000);
}

#[test]
fn dump_derive_without_hh1_and_without_hh6() {
    assert!(check_derive(|r| r["place"] == "ongudai_no_hh1") > 50);
    assert!(check_derive(|r| r["place"] == "ongudai_no_hh6") > 50);
}

#[test]
fn dump_derive_peak_of_day_without_hour() {
    let n = check_derive(|r| r["hour"].is_null());
    assert!(n > 400, "строк {n}");
}

#[test]
fn dump_derive_morning_inversion_and_evening() {
    let n = check_derive(|r| matches!(r["hour"].as_f64(), Some(h) if h <= 9.0 || h >= 19.0));
    assert!(n > 800, "строк {n}");
}

#[test]
fn dump_derive_key_set_matches() {
    for r in kind_rows("derive").step_by(97) {
        let ctx = row_ctx(r, false);
        let cp = climate_place(&r["cell"], &ctx, cfg());
        let w = derive(
            &forecast_of(&r["forecast"]),
            &ctx,
            f(&r["hour"]),
            &cp,
            cfg(),
        );
        let mut a: Vec<_> = w.keys().cloned().collect();
        let mut b: Vec<_> = r["weather"].as_object().unwrap().keys().cloned().collect();
        a.sort();
        b.sort();
        assert_eq!(a, b);
        let mut a: Vec<_> = w["_derived"].as_object().unwrap().keys().cloned().collect();
        let mut b: Vec<_> = r["weather"]["_derived"]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        a.sort();
        b.sort();
        assert_eq!(a, b, "ключи _derived");
    }
}

#[test]
fn dump_dew_point_is_td_day_clamped_to_temperature() {
    for r in kind_rows("derive").step_by(11) {
        let ctx = row_ctx(r, false);
        let cp = climate_place(&r["cell"], &ctx, cfg());
        let fc = forecast_of(&r["forecast"]);
        let td = td_day(fc.temperature_c, &fc.sky, &cp, &ctx, cfg());
        let t = f(&r["weather"]["_derived"]["temperature_c"]);
        let want = f(&r["weather"]["_derived"]["dew_point_c"]);
        let got = td.min(t);
        assert!(
            (got - want).abs() <= REL * want.abs() + ABS,
            "{got} против {want}"
        );
    }
}

#[test]
fn dump_haze_and_rh_follow_temperature_and_dew_point() {
    for r in kind_rows("derive").step_by(7) {
        let d = &r["weather"]["_derived"];
        let h = haze_k_rh(f(&d["temperature_c"]), f(&d["dew_point_c"]), cfg());
        let want = f(&r["weather"]["haze_k"]);
        assert!(
            (h - want).abs() <= REL * want.abs() + ABS,
            "{h} против {want}"
        );
    }
}

#[test]
fn dump_cirrus_base_cover_before_storm_and_sky() {
    for r in kind_rows("derive").step_by(5) {
        let ctx = row_ctx(r, false);
        let cp = climate_place(&r["cell"], &ctx, cfg());
        let fc = forecast_of(&r["forecast"]);
        let cb = f(&r["weather"]["cb_chance"]);
        // cb_chance в словаре уже умножен на cb_k неба; cirrus_cover — после max с sky.cover.
        let base = cirrus_base_cover(&cp, &fc.sky, &ctx, cfg());
        assert!((0.0..=1.0).contains(&base));
        let cover = f(&r["weather"]["cirrus_cover"]);
        assert!(
            cover >= base.min(1.0) - 1e-9 || cb > 0.0,
            "{cover} < {base}"
        );
        let sb = sun_block_cover(r["weather"].as_object().unwrap());
        assert!((0.0..=1.0).contains(&sb));
    }
}

// ---------------------------------------------------------------- td_noise

#[test]
fn splitmix64_reference_vector() {
    // splitmix64 с состоянием 0: первый выход 0xE220A8397B1DCDAF.
    assert_eq!(splitmix64(0) as u64, 0xE220_A839_7B1D_CDAF);
}

#[test]
fn td_noise_is_deterministic_and_depends_on_place_and_date() {
    let a = td_noise(7, 15, 50.79, 86.13);
    assert_eq!(a, td_noise(7, 15, 50.79, 86.13));
    assert_ne!(a, td_noise(7, 16, 50.79, 86.13));
    assert_ne!(a, td_noise(8, 15, 50.79, 86.13));
    assert_ne!(a, td_noise(7, 15, 50.80, 86.13));
    assert_ne!(a, td_noise(7, 15, 50.79, 86.14));
    // округление до 0,01°: меньшее смещение — то же число
    assert_eq!(a, td_noise(7, 15, 50.7901, 86.1299));
}

#[test]
fn td_noise_is_standard_normal() {
    let mut s = 0.0;
    let mut s2 = 0.0;
    let mut n = 0.0;
    for m in 1..=12 {
        for d in 1..=28 {
            for k in 0..30 {
                let x = td_noise(m, d, -60.0 + 4.0 * k as f64, 7.0 * k as f64 - 100.0);
                assert!(x.is_finite());
                s += x;
                s2 += x * x;
                n += 1.0;
            }
        }
    }
    let mean = s / n;
    let var = s2 / n - mean * mean;
    assert!(mean.abs() < 0.08, "среднее {mean}");
    assert!((var - 1.0).abs() < 0.12, "дисперсия {var}");
}

// ---------------------------------------------------------------- test_weather_model.gd

fn reference(month: i64, which: &str) -> (PlaceCtx, ClimatePlace) {
    let r = kind_rows("reference")
        .find(|r| match which {
            "altai" => r["ctx"]["lat"] == 51.87 && r["ctx"]["month"] == month,
            "cairns" => r["ctx"]["lat"] == -16.9,
            _ => r["ctx"]["lat"] == 51.9,
        })
        .unwrap();
    let ctx = row_ctx(r, false);
    (ctx, climate_place(&r["cell"], &ctx, cfg()))
}

fn fc(t: f64, wind: f64, sky: &str) -> Forecast {
    Forecast {
        temperature_c: t,
        wind_speed_kmh: wind,
        wind_from_deg: 270.0,
        sky: sky.into(),
    }
}

fn derive_ref(t: f64, wind: f64, month: i64) -> Map<String, Value> {
    let (ctx, cp) = reference(month, "altai");
    derive(&fc(t, wind, "clear"), &ctx, f64::NAN, &cp, cfg())
}

fn at_hour(t: f64, hour: f64, wind: f64, sky: &str) -> Map<String, Value> {
    let (ctx, cp) = reference(7, "altai");
    derive(&fc(t, wind, sky), &ctx, hour, &cp, cfg())
}

fn g(w: &Map<String, Value>, k: &str) -> f64 {
    w[k].as_f64().unwrap_or_else(|| panic!("{k} не число"))
}

fn g2(w: &Map<String, Value>, k: &str, i: usize) -> f64 {
    w[k][i].as_f64().unwrap()
}

fn rel(a: f64, b: f64) -> f64 {
    (a - b).abs() / b.abs().max(1.0e-6)
}

fn preset(id: &str) -> Value {
    let p = root().join(format!("configs/weather/{id}.json"));
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

#[test]
fn gd_reference_forecasts_match_presets() {
    for (id, t, u) in [
        ("weak", 21.0, 7.0),
        ("medium", 26.0, 11.0),
        ("strong", 33.0, 18.0),
        ("storm", 34.0, 14.0),
    ] {
        let w = derive_ref(t, u, 7);
        let p = preset(id);
        let pf = |k: &str, i: usize| p[k][i].as_f64().unwrap();
        assert!(
            rel(
                g2(&w, "thermal_strength_ms", 1),
                pf("thermal_strength_ms", 1)
            ) <= 0.2,
            "{id} сила макс"
        );
        if id == "storm" {
            let cb = g(&w, "cb_chance");
            assert!((0.2..=0.45).contains(&cb), "storm cb {cb}");
            continue;
        }
        assert!(
            rel(
                g2(&w, "thermal_strength_ms", 0),
                pf("thermal_strength_ms", 0)
            ) <= 0.2,
            "{id} сила мин"
        );
        assert!(
            rel(
                g(&w, "cloudbase_agl_m"),
                p["cloudbase_agl_m"].as_f64().unwrap()
            ) <= 0.2,
            "{id} кромка"
        );
        let near = |k: &str, tol: f64| {
            let (a, b) = (g(&w, k), p[k].as_f64().unwrap());
            assert!((a - b).abs() <= tol, "{id} {k}: {a} против {b}");
        };
        near("dry_thermal_fraction", 0.12);
        near("background_sink_ms", 0.15);
        if id == "strong" {
            let e = g(&w, "thermal_extreme_chance");
            assert!((0.02..=0.06).contains(&e), "extreme {e}");
        } else {
            near("cb_chance", 1e-6);
            assert!(g(&w, "thermal_extreme_chance").abs() < 1e-6);
        }
    }
}

#[test]
fn gd_monotonic_in_temperature() {
    let mut prev = derive_ref(10.0, 11.0, 7);
    for t in 11..35 {
        let w = derive_ref(t as f64, 11.0, 7);
        assert!(
            g(&w, "cloudbase_agl_m") >= g(&prev, "cloudbase_agl_m") - 1e-3,
            "кромка убыла при {t}"
        );
        assert!(
            g2(&w, "thermal_strength_ms", 1) >= g2(&prev, "thermal_strength_ms", 1) - 1e-3,
            "сила убыла при {t}"
        );
        prev = w;
    }
}

#[test]
fn gd_wind_weakens_thermals_and_blows_dust_away() {
    let mut prev = derive_ref(28.0, 0.0, 7);
    for u in (0..46).step_by(3) {
        let w = derive_ref(28.0, u as f64, 7);
        assert!(
            g2(&w, "thermal_strength_ms", 1) <= g2(&prev, "thermal_strength_ms", 1) + 1e-4,
            "сила выросла при ветре {u}"
        );
        if u >= 30 {
            assert!(
                g(&w, "dust_devil_chance").abs() < 1e-6,
                "пылевые вихри при {u}"
            );
        }
        prev = w;
    }
    assert!(g(&derive_ref(28.0, 0.0, 7), "dust_devil_chance") > 0.0);
}

#[test]
fn gd_blue_and_dead_days() {
    let w16 = derive_ref(16.0, 7.0, 7);
    assert!(
        g(&w16, "cloud_min_strength_ms") >= 50.0,
        "+16 июль — голубой"
    );
    assert!((g(&w16, "dry_thermal_fraction") - 1.0).abs() < 1e-6);
    let w12 = derive_ref(12.0, 7.0, 7);
    assert!(
        (g(&w12, "cloudbase_agl_m") - 300.0).abs() < 1e-3,
        "+12 — кромка на минимуме"
    );
}

#[test]
fn gd_spring_air_is_livelier() {
    let apr = derive_ref(15.0, 7.0, 4);
    let jul = derive_ref(15.0, 7.0, 7);
    assert!(g(&apr, "cloudbase_agl_m") > g(&jul, "cloudbase_agl_m") + 300.0);
    assert!(g2(&apr, "thermal_strength_ms", 1) > g2(&jul, "thermal_strength_ms", 1));
}

#[test]
fn gd_wave_off_by_default_and_on_by_config() {
    for t in [-5.0, 10.0, 18.0, 26.0, 38.0] {
        for u in [0.0, 20.0, 36.0, 43.0] {
            assert!(
                g(&derive_ref(t, u, 7), "wave_strength").abs() < 1e-9,
                "волна при {t}/{u}"
            );
        }
    }
    let mut on = cfg().clone();
    on.raw["wave"]["enabled"] = Value::Bool(true);
    let (ctx, cp) = reference(7, "altai");
    let w = derive(&fc(18.0, 36.0, "clear"), &ctx, f64::NAN, &cp, &on);
    assert!(g(&w, "wave_strength") > 0.0, "волна включается конфигом");
}

#[test]
fn gd_deterministic_and_complete() {
    const KEYS: [&str; 24] = [
        "wind_speed_kmh",
        "wind_from_deg",
        "cloudbase_agl_m",
        "thermal_strength_ms",
        "thermal_radius_m",
        "thermal_spacing_m",
        "thermal_duty",
        "background_sink_ms",
        "convective_turbulence_ms",
        "cloud_min_strength_ms",
        "cloud_depth_m",
        "street_strength",
        "overdevelopment_chance",
        "cloud_size_factor",
        "cirrus_cover",
        "cb_chance",
        "cb_top_above_base_m",
        "wave_strength",
        "stability_n_per_s",
        "lens_level_above_crest_m",
        "dry_thermal_fraction",
        "thermal_extreme_chance",
        "thermal_extreme_ms",
        "dust_devil_chance",
    ];
    let a = derive_ref(26.0, 11.0, 7);
    assert_eq!(a, derive_ref(26.0, 11.0, 7), "одни входы — один день");
    for k in KEYS {
        let v = a.get(k).unwrap_or_else(|| panic!("нет ключа {k}"));
        match v {
            Value::Array(e) => assert!(
                e.iter().all(|x| x.as_f64().is_some_and(f64::is_finite)),
                "{k}"
            ),
            _ => assert!(v.as_f64().is_some_and(f64::is_finite), "{k} — не число"),
        }
    }
}

#[test]
fn gd_typical_max_fallback_table_without_grids() {
    // Без ячейки (нет сеток): Tx — таблица typical_max_c, амплитуда — diurnal.range_k.
    let (ctx, _) = reference(7, "altai");
    let cp = climate_place(&Value::Null, &ctx, cfg());
    assert!((cp.tx_c - 26.0).abs() < 1e-6, "обычно в июле +26");
    assert!((cp.dtr_k - 11.0).abs() < 1e-9, "амплитуда без места");
    assert_eq!(cp.src.hh5, "none");
    assert!((cp.gain_per_km - cfg().altitude_gain_per_km).abs() < 1e-12);
}

#[test]
fn gd_place_climate_wired() {
    let (ctx, cp) = reference(1, "cairns");
    let w = derive(&fc(33.0, 10.0, "clear"), &ctx, f64::NAN, &cp, cfg());
    let d = w["_derived"].as_object().unwrap();
    assert!(
        (g(d, "trop_msl_m") - cp.trop_m).abs() < 1e-6,
        "тропопауза места в derive"
    );
    assert!(
        (g(d, "gain_per_km") - cp.gain_per_km).abs() < 1e-9,
        "рост ветра места в derive"
    );
    if cp.src.hh6 != "none" {
        let k_clear = cirrus_base_cover(&cp, "clear", &ctx, cfg());
        let k_over = cirrus_base_cover(&cp, "overcast", &ctx, cfg());
        assert!(k_over > k_clear, "перистые: пасмурный день гуще ясного");
        let k = cfg().raw["hcc_sky"]["k_sky"]["clear"][0][2]
            .as_f64()
            .unwrap();
        assert!(
            (k_clear - cp.hcc * k).abs() < 1e-9,
            "ясно, пояс 0–20°, январь юга = ИИА"
        );
    }
    // β-член от Tx места: в день с Tmax = Tx места поправки на температуру нет
    let tx = cp.tx_c;
    let td0 = td_day(tx, "clear", &cp, &ctx, cfg());
    let td1 = td_day(tx + 5.0, "clear", &cp, &ctx, cfg());
    let tdc = &cfg().raw["td_day"];
    let b = tdc["bands_abs_lat"]
        .as_array()
        .unwrap()
        .iter()
        .position(|x| ctx.lat.abs() <= x.as_f64().unwrap())
        .unwrap();
    let sn = dp_air::field::weather_core::season_index(1, ctx.lat);
    let beta = tdc["sky"]["clear"]["beta"][b][sn].as_f64().unwrap();
    assert!(
        (td1 - td0 - beta * 5.0).abs() < 0.1,
        "сдвиг Td при Tmax = Tx + 5 К равен β·5"
    );
    let mu = tdc["sky"]["clear"]["mu_sigma"][b][sn].as_f64().unwrap();
    let rho = tdc["sky"]["clear"]["res_ratio"][b][sn].as_f64().unwrap();
    let r = td_noise(1, 15, ctx.lat, ctx.lon).clamp(-3.0, 3.0);
    assert!(
        (td0 - (cp.td_c + (mu + r * rho) * cp.td_sd_k)).abs() < 0.1,
        "при Tmax = Tx места Td = климат + μσ + rρσ"
    );
    // Без valley_msl_m (и с NaN) поправок на высоту нет: значения на средней высоте ячейки
    let nov = kind_rows("reference")
        .find(|r| r["ctx"]["lat"] == 51.9)
        .unwrap();
    assert!(nov["ctx"].get("valley_msl_m").is_none());
    let (nctx, ncp) = reference(7, "nov");
    assert!(nctx.valley_msl_m.is_nan());
    assert!(
        (ncp.tx_c - f(&nov["cell"]["tx_c"])).abs() < 1e-9,
        "без valley_msl_m Tx = на высоте ячейки"
    );
    assert!(
        (ncp.td_c - f(&nov["cell"]["td_c"])).abs() < 1e-9,
        "без valley_msl_m Td = на высоте ячейки"
    );
}

#[test]
fn gd_speed() {
    let (ctx, cp) = reference(7, "altai");
    let t0 = std::time::Instant::now();
    for i in 0..100 {
        derive(
            &fc(20.0 + i as f64 * 0.1, 11.0, "clear"),
            &ctx,
            f64::NAN,
            &cp,
            cfg(),
        );
    }
    let per_ms = t0.elapsed().as_secs_f64() * 1000.0 / 100.0;
    // GD: < 1 мс; в cargo test (без оптимизации) запас на порядок
    assert!(per_ms < 5.0, "derive {per_ms:.3} мс");
}

#[test]
fn gd_day_course() {
    let m9 = at_hour(26.0, 9.0, 11.0, "clear");
    let m14 = at_hour(26.0, 14.0, 11.0, "clear");
    let m19 = at_hour(26.0, 19.0, 11.0, "clear");
    let temp = |w: &Map<String, Value>| g(w["_derived"].as_object().unwrap(), "temperature_c");
    assert!(temp(&m9) < temp(&m14) - 2.0, "утром прохладнее");
    assert!(
        g2(&m9, "thermal_strength_ms", 1) < g2(&m14, "thermal_strength_ms", 1) * 0.7,
        "утром слабее"
    );
    assert!(
        g(&m9, "cloudbase_agl_m") < g(&m14, "cloudbase_agl_m") - 500.0,
        "утром кромка ниже"
    );
    assert!(
        (g(&m9, "dry_thermal_fraction") - 1.0).abs() < 0.05,
        "в 9 ч облаков почти нет"
    );
    let mut prev = -1.0;
    for h in [8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0] {
        let cb = g(&at_hour(26.0, h, 11.0, "clear"), "cloudbase_agl_m");
        assert!(cb >= prev - 1.0, "кромка поднимается до пика ({h} ч: {cb})");
        prev = cb;
    }
    assert!(
        g(&at_hour(26.0, 12.0, 11.0, "clear"), "dry_thermal_fraction") < 0.5,
        "к полудню кучевые"
    );
    assert!(
        g(&m19, "thermal_duty") < g(&m14, "thermal_duty") * 0.6,
        "вечером термиков меньше"
    );
    assert!(
        g2(&m19, "thermal_radius_m", 1) > g2(&m14, "thermal_radius_m", 1),
        "вечером шире"
    );
    assert!(
        g(&m19, "thermal_edge_k") < g(&m14, "thermal_edge_k"),
        "вечером край мягче"
    );
    assert!(
        g(&at_hour(26.0, 20.0, 11.0, "clear"), "mech_turbulence_k") < 0.9,
        "к закату спокойнее"
    );
    let peak = derive_ref(26.0, 11.0, 7);
    assert!(
        rel(
            g2(&m14, "thermal_strength_ms", 1),
            g2(&peak, "thermal_strength_ms", 1)
        ) < 0.1,
        "14 ч ≈ разгар дня"
    );
    assert!(
        g(&at_hour(34.0, 10.0, 11.0, "clear"), "cb_chance") < 0.05,
        "утром гроз нет"
    );
    assert!(
        g(&at_hour(34.0, 15.0, 11.0, "clear"), "cb_chance") > 0.2,
        "днём в жару грозы"
    );
}

#[test]
fn gd_sky_cover() {
    let clear = at_hour(31.0, 14.0, 11.0, "clear");
    let partly = at_hour(31.0, 14.0, 11.0, "partly");
    let over = at_hour(31.0, 14.0, 11.0, "overcast");
    assert!(g2(&partly, "thermal_strength_ms", 1) < g2(&clear, "thermal_strength_ms", 1));
    assert!(g2(&over, "thermal_strength_ms", 1) < g2(&partly, "thermal_strength_ms", 1));
    assert!(
        g(&over, "thermal_duty") < g(&clear, "thermal_duty") * 0.6,
        "облачно — термиков мало"
    );
    assert!(
        g(&over, "cb_chance").abs() < 1e-6,
        "под облачностью гроз нет"
    );
    assert!(g(&over, "cirrus_cover") >= 0.8, "пелена облачности");
    assert!(
        g2(&over, "thermal_radius_m", 1) > g2(&clear, "thermal_radius_m", 1),
        "облачно — мягкие"
    );
    assert_eq!(
        at_hour(31.0, 14.0, 11.0, "nope")["thermal_strength_ms"],
        clear["thermal_strength_ms"],
        "неизвестная облачность — ясно"
    );
    // пелена неба не гасит солнце второй раз
    assert!(sun_block_cover(&over) < g(&over, "cirrus_cover"));
}

#[test]
fn gd_spring_plus15_is_a_thermal_day() {
    let w = derive_ref(15.0, 11.0, 4);
    assert!(
        g(&w, "cloudbase_agl_m") > 1200.0,
        "апрель +15: верх {}",
        g(&w, "cloudbase_agl_m")
    );
    assert!(g2(&w, "thermal_strength_ms", 1) > 2.5, "апрель +15: сила");
}
