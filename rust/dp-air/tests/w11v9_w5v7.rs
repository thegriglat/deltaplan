//! W5 v7 и W11 v9 на стороне `dp-air`: `loc.climate_lag` (вода берёт климат даты `месяц/день −
//! lag_days`, остальное — `loc.climate`) и поле без предела по времени (`air.timeout_s` удалён).
//! Стенки и земля после стартов решателя (W11 v9) — `rust/picard_rs/tests/walls_v9.rs`.
use dp_air::field::runtime::{Faults, PlaceClimate, RtCfg, Start};
use dp_air::field::weather_core::{
    Climate, ClimateCell, Domain, WeatherConfigs, context, field_weather, hour_at, water_mean_air_c,
};
use dp_air::fixtures::read_place;
use dp_air::{AirModel, Code, Conditions, Configs, Formula, LocClimate, Place, PlaceHeader, State};
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
            out.push((name, std::fs::read_to_string(&p).unwrap()));
        }
    }
}

fn configs_with(patch: impl Fn(&mut Value)) -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere.json" {
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

fn lc(tx: f64, dtr: f64) -> LocClimate {
    LocClimate {
        tx_c: tx,
        dtr_k: dtr,
        z_cell_m: 900.0,
        has_hh1: true,
        has_hh5: true,
    }
}

fn with_climate(p: &Place, c: Option<LocClimate>, lag: Option<LocClimate>) -> Place {
    let mut h = p.header().clone();
    h.loc.climate = c;
    h.loc.climate_lag = lag;
    Place::new(
        h,
        p.heights().to_vec(),
        p.water().to_vec(),
        p.cls().to_vec(),
        p.moist().to_vec(),
    )
    .unwrap()
}

const HEAD: &str = r#"{"version":1,"loc":{"id":"t","center_lat":50.0,"center_lon":86.0,
"utc_offset_h":7.0,"month":7,"day":1,CLIM},"grid":{"origin_x":-100,"origin_z":-100,"spacing":50,
"width":5,"height":4},"surface_classes":{"grass":1},"start_sites":[]}"#;
const C: &str = r#""tx_c":20.0,"dtr_k":10.0,"z_cell_m":0.0,"has_hh1":false,"has_hh5":true"#;

// ---------------------------------------------------------------- W5 v7: разбор

#[test]
fn climate_lag_is_required_with_climate_and_named_in_the_error() {
    let ok = |clim: &str| PlaceHeader::from_json(&HEAD.replace(",CLIM", clim));
    let both = format!(r#","climate":{{{C}}},"climate_lag":{{{C}}}"#);
    let h = ok(&both).unwrap();
    assert_eq!(h.loc.climate_lag, h.loc.climate);
    let only = format!(r#","climate":{{{C}}}"#);
    let e = ok(&only).unwrap_err();
    assert_eq!(e.code, Code::BadInput);
    assert!(e.to_string().contains("climate_lag"), "{e}");
    // без обоих ключей — запасные таблицы (как до v7)
    assert!(ok("").unwrap().loc.climate_lag.is_none());
    // климат с неполным lag — BAD_INPUT
    let bad = format!(r#","climate":{{{C}}},"climate_lag":{{"tx_c":1.0}}"#);
    assert_eq!(ok(&bad).unwrap_err().code, Code::BadInput);
}

#[test]
fn baked_places_carry_climate_lag() {
    for n in ["synthetic", "ongudai"] {
        let h = place(n).header().clone();
        assert!(h.loc.climate.is_some(), "{n}");
        let lag = h
            .loc
            .climate_lag
            .unwrap_or_else(|| panic!("{n}: climate_lag"));
        assert!(lag.tx_c.is_finite() && lag.dtr_k > 0.0, "{n}");
    }
}

// ---------------------------------------------------------------- W5 v7: вода берёт lag

#[test]
fn place_climate_gives_lag_cell_for_water_and_climate_for_the_rest() {
    let cfg = RtCfg::from_configs(&configs_with(|_| {})).unwrap();
    let (c, l) = (lc(25.0, 11.0), lc(15.0, 8.0));
    let pc = PlaceClimate {
        table: &cfg.climate,
        loc: Some(c),
        lag: Some(l),
    };
    let (a, w) = (pc.cell(50.0, 86.0, 7, 15), pc.water_cell(50.0, 86.0, 6, 15));
    assert_eq!((a.tx_c, a.dtr_k), (25.0, 11.0));
    assert_eq!((w.tx_c, w.dtr_k), (15.0, 8.0));
    // без lag (нет климата места) вода — как cell: запасные таблицы
    let none = PlaceClimate {
        table: &cfg.climate,
        loc: None,
        lag: None,
    };
    let (a, w) = (
        none.cell(50.0, 86.0, 6, 15),
        none.water_cell(50.0, 86.0, 6, 15),
    );
    assert_eq!((a.tx_c, a.dtr_k), (w.tx_c, w.dtr_k));
}

#[test]
fn water_mean_air_takes_climate_lag_in_field_weather() {
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
    let run = |c: LocClimate, lag: LocClimate| {
        let p = with_climate(&base, Some(c), Some(lag));
        let clim = PlaceClimate {
            table: &rt.climate,
            loc: p.header().loc.climate,
            lag: p.header().loc.climate_lag,
        };
        let fw = field_weather(&cond, &p, &wc, &configs, &clim, hour, &dom).unwrap();
        (fw.water_mean_air_c, fw.t_max, fw.ctx)
    };
    let (w1, t1, ctx) = run(lc(22.0, 10.0), lc(14.0, 9.0));
    let (w2, t2, _) = run(lc(22.0, 10.0), lc(24.0, 9.0));
    let (w3, t3, _) = run(lc(30.0, 10.0), lc(14.0, 9.0));
    assert_eq!(t1, t2, "lag не трогает дневной максимум");
    assert!(w2 > w1 + 5.0, "тёплый lag греет воду: {w1} -> {w2}");
    assert!(t3 > t1 + 5.0, "loc.climate двигает воздух");
    assert_eq!(w1, w3, "loc.climate воду не трогает");
    // значение: среднее суточное при климате lag, как в SurfaceHeat.water_temp_c
    let lag = lc(14.0, 9.0);
    let as_lag = move |_: f64, _: f64, _: i64, _: i64| ClimateCell {
        tx_c: lag.tx_c,
        dtr_k: lag.dtr_k,
        z_cell_m: lag.z_cell_m,
        has_hh1: lag.has_hh1,
        has_hh5: lag.has_hh5,
    };
    assert_eq!(w1, water_mean_air_c(&wc, &ctx, &as_lag));
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
