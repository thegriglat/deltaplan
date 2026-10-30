//! W5 v7 и W11 v9 на стороне `dp-air`: климат места из `Weather` (W5 v10; вода берёт дату `месяц/день −
//! lag_days`) и поле без предела по времени (`air.timeout_s` удалён).
//! Стенки и земля после стартов решателя (W11 v9) — `rust/picard_rs/tests/walls_v9.rs`.
mod common;

use common::real_weather;
use dp_air::field::runtime::{Faults, PlaceClimate, RtCfg, Start};
use dp_air::field::weather_core::{
    Climate, Domain, WeatherConfigs, context, field_weather, hour_at, water_mean_air_c,
};
use dp_air::fixtures::read_place;
use dp_air::weather::Weather;
use dp_air::{AirModel, Conditions, Configs, Formula, Place, PlaceHeader, State};
use picard_rs::api::StopReason as Stop;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
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
            out.push((
                name.trim_end_matches(".json").to_string(),
                std::fs::read_to_string(&p).unwrap(),
            ));
        }
    }
}

fn configs_with(patch: impl Fn(&mut Value)) -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere" {
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

const HEAD: &str = r#"{"version":1,"loc":{"id":"t","center_lat":50.0,"center_lon":86.0,
"utc_offset_h":7.0,"month":7,"day":1},"grid":{"origin_x":-100,"origin_z":-100,"spacing":50,
"width":5,"height":4},"surface_classes":{"grass":1},"start_sites":[]}"#;

// ---------------------------------------------------------------- W5 v10: климат берёт Weather

#[test]
fn header_climate_keys_are_gone_and_old_ones_ignored() {
    let old = HEAD.replace(
        r#""day":1}"#,
        r#""day":1,"climate":{"tx_c":20.0},"climate_lag":{"tx_c":1.0}}"#,
    );
    assert_eq!(PlaceHeader::from_json(&old).unwrap().loc.day, 1);
    for n in ["synthetic", "ongudai"] {
        assert_eq!(place(n).header().loc.month, 7, "{n}");
    }
}

// ---------------------------------------------------------------- W5 v7: вода берёт дату со сдвигом

#[test]
fn place_climate_gives_weather_cells_and_tables_without_weather() {
    let cfg = RtCfg::from_configs(&configs_with(|_| {})).unwrap();
    let w = real_weather();
    let pc = PlaceClimate::of(&cfg.climate, Some(&w));
    let (a, l) = (pc.cell(50.0, 86.0, 7, 15), pc.water_cell(50.0, 86.0, 6, 15));
    let (ca, cl) = (
        w.climate_at(50.0, 86.0, 7, 15),
        w.climate_at(50.0, 86.0, 6, 15),
    );
    assert_eq!(
        (a.tx_c, a.dtr_k, a.z_cell_m),
        (ca.tx_c, ca.dtr_k, ca.z_cell_m)
    );
    assert_eq!((l.tx_c, l.dtr_k), (cl.tx_c, cl.dtr_k));
    assert!(a.has_hh1 && a.has_hh5 && a.z_cell_m > 0.0);
    // без Weather - запасные таблицы, вода как cell
    let none = PlaceClimate::of(&cfg.climate, None);
    let (a, w) = (
        none.cell(50.0, 86.0, 6, 15),
        none.water_cell(50.0, 86.0, 6, 15),
    );
    assert_eq!((a.tx_c, a.dtr_k), (w.tx_c, w.dtr_k));
    assert!(!a.has_hh1 && !a.has_hh5);
}

#[test]
fn water_mean_air_takes_shifted_date_in_field_weather() {
    let configs = configs_with(|_| {});
    let rt = RtCfg::from_configs(&configs).unwrap();
    let wc = WeatherConfigs::from_configs(&configs).unwrap();
    let base = place("synthetic");
    let cond = Conditions::from_json(
        r#"{"preset":"medium","start_hour":12,"speed":1,"blend_s":null,"rebuild":false}"#,
    )
    .unwrap();
    let hour = hour_at(&cond, 0.0);
    let dom = Domain {
        x0: -4000.0,
        y0: -4000.0,
        nx: 20,
        ny: 20,
        dx: 400.0,
    };
    let w = real_weather();
    let run = |wx: Option<&Weather>| {
        let clim = PlaceClimate::of(&rt.climate, wx);
        let fw = field_weather(&cond, &base, &wc, &configs, &clim, hour, &dom).unwrap();
        (fw.water_mean_air_c, fw.t_max, fw.ctx)
    };
    let (w1, t1, ctx) = run(Some(&w));
    let (w0, t0, _) = run(None);
    assert!(
        (w1 - w0).abs() > 0.1 || (t1 - t0).abs() > 0.1,
        "сетки климата двигают воздух"
    );
    // значение: среднее суточное при климате даты сдвига, как в SurfaceHeat.water_temp_c
    let wr: &Weather = &w;
    let by_weather = move |lat: f64, lon: f64, m: i64, d: i64| wr.cell(lat, lon, m, d);
    assert_eq!(w1, water_mean_air_c(&wc, &ctx, &by_weather));
    assert_eq!(ctx.month, context(&base).month);
}

// ---------------------------------------------------------------- без таймаута, грубый старт

fn cheap(v: &mut Value) {
    v["air"]["deterministic"] = json!(true);
    v["air"]["domain_l_m"] = json!(7200.0);
    v["air"]["threads"] = json!(4);
    v["air"]["tol_scale"] = json!(5.0);
    v["air_model"]["edge_blend_cells"] = json!(1.0);
}

/// Синтетика, ветер `strong`, без окон: ждём READY, отдаём модель.
fn ready(cfg: &Configs) -> (Formula, f64) {
    let mut m = Formula::new().with_faults(Faults {
        no_windows: true,
        ..Default::default()
    });
    m.configure(cfg, 1).unwrap();
    m.set_conditions(
        &Conditions::from_json(
            r#"{"preset":"strong","start_hour":12,"speed":1,"blend_s":null,"rebuild":false}"#,
        )
        .unwrap(),
    )
    .unwrap();
    m.load_place(place("synthetic")).unwrap();
    let t0 = Instant::now();
    loop {
        match m.status().state {
            State::Ready => break,
            State::Failed => panic!("Failed: {}", m.status().reason),
            _ => {}
        }
        assert!(t0.elapsed().as_secs() < 900, "no Ready");
        std::thread::sleep(Duration::from_millis(2));
    }
    (m, t0.elapsed().as_secs_f64())
}

#[test]
fn field_has_no_time_limit() {
    // Ключ в конфиге — неизвестный, не ошибка и ничего не ограничивает: при прежних правилах
    // (max(1, timeout_s) на проход) подготовка не дошла бы до Ready. Длительность не проверяем
    // (зависит от скорости машины): `ready` возвращает модель только в состоянии Ready.
    let cfg = configs_with(|v| {
        cheap(v);
        v["air"]["timeout_s"] = json!(0.001);
    });
    let (m, _) = ready(&cfg);
    assert_eq!(m.status().state, State::Ready);
    let r = m.report().unwrap();
    assert!(
        r.passes[0]
            .stop
            .iter()
            .all(|s| matches!(s, Stop::Converged | Stop::AllFrozen)),
        "stop {:?}",
        r.passes[0].stop
    );
}

/// W11 v9: после грубого старта (стенки и земля обнулены, дальние грани типа 3 — фон, как
/// `K_BC`) расчёт сходится; без дальних граней остаётся постоянная дивергенция (чистый поток
/// через границу, который проекция снять не может) и 3000 итераций MaxIters.
#[test]
fn coarse_start_of_strong_wind_converges_with_walls_zeroed() {
    let cfg = configs_with(cheap);
    let (m, _) = ready(&cfg);
    let r = m.report().unwrap();
    let p = &r.passes[0];
    assert_eq!(p.start, Start::Coarse);
    assert!(
        p.stop
            .iter()
            .all(|s| matches!(s, Stop::Converged | Stop::AllFrozen)),
        "stop {:?}, iters {:?}",
        p.stop,
        p.iters
    );
    assert!(p.iters.iter().all(|&n| n < 600), "iters {:?}", p.iters);
}
