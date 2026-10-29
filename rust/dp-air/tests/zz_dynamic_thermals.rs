//! RW-P6: динамические термики (mode 0) на месте «как в игровых тестах `air_rig.gd`»: сетка из
//! функций (холмы, луг, влажность 1), без статик, пресет `strong` словарём.
//!
//! Причина «cores() пуст» в `test_atmosphere.gd` (RW-P4): стенд брал шаг сетки 100 м, а поле
//! Пикара принимает только 25 м (`weather_core::Domain::check`) - загрузка → `Failed`, опросы
//! слагаемых отдавали пусто (`Formula::query` требовал `Ready`), а у места без поля источники
//! термиков по клеткам слабее порога `sun_min`. Статичные термики (mode 1) от погоды и поля не
//! зависят - потому были. Игровое место всегда 25 м - в игре термики на месте есть.
//! Второе: вне детерминированного режима первый набор термиков собирается в фоне, и до его
//! публикации (десятки-сотни мс) `cores` пуст - тест ждёт.
use dp_air::{AirModel, Conditions, Configs, Core, Focus, Formula, Place, PlaceHeader, State};
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

/// Конфиги игры; `det` - детерминированный режим и малая область поля (проверки -O0).
fn configs(det: bool) -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere.json" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = json!(det);
            v["air"]["domain_l_m"] = json!(7200.0);
            v["air"]["threads"] = json!(4);
            v["air"]["tol_scale"] = json!(5.0);
            v["air_model"]["edge_blend_cells"] = json!(1.0);
            v["air_model"]["window_levels_m"] = json!([]);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

fn hills(x: f64, z: f64) -> f64 {
    400.0 + 150.0 * (x / 700.0).sin() * (z / 900.0).cos()
}

/// Как `AirPlaceData.from_functions` стенда: квадрат 10 км с шагом `sp`, луг, влажность 1.
fn rig_place(sp: f64) -> Place {
    let half = 5000.0f64;
    let n = (2.0 * half / sp).round() as usize + 1;
    let h = format!(
        r#"{{"version":1,"loc":{{"id":"rig","center_lat":51.5,"center_lon":86.5,"utc_offset_h":6.0,
        "month":7,"day":15,
        "climate":{{"tx_c":24.0,"dtr_k":12.0,"z_cell_m":0.0,"has_hh1":false,"has_hh5":true}},
        "climate_lag":{{"tx_c":22.0,"dtr_k":12.0,"z_cell_m":0.0,"has_hh1":false,"has_hh5":true}}}},
        "grid":{{"origin_x":{},"origin_z":{},"spacing":{sp},"width":{n},"height":{n}}},
        "surface_classes":{{"none":0,"forest":1,"grass":2,"crop":3,"shrub":4,"bare":5,"water":6,"built":7,"snow":8}},
        "start_sites":[]}}"#,
        -half, -half
    );
    let header = PlaceHeader::from_json(&h).unwrap();
    let mut hs = Vec::with_capacity(n * n);
    for j in 0..n {
        for i in 0..n {
            hs.push(hills(-half + sp * i as f64, -half + sp * j as f64) as f32);
        }
    }
    Place::new(header, hs, vec![0; n * n], vec![2; n * n], vec![1.0; n * n]).unwrap()
}

/// Пресет `name` целиком словарём (как `Rig.preset` в GDScript).
fn preset_obj(name: &str) -> String {
    std::fs::read_to_string(repo().join(format!("configs/weather/{name}.json"))).unwrap()
}

fn formula(det: bool, preset: &str, sp: f64) -> Formula {
    let mut m = Formula::new();
    m.configure(&configs(det), 7).unwrap();
    let c = format!(
        r#"{{"preset":{preset},"start_hour":12,"speed":1,"blend_s":null,"rebuild":false,"inflow_mode":"inflow"}}"#
    );
    m.set_conditions(&Conditions::from_json(&c).unwrap())
        .unwrap();
    m.set_focuses(&[Focus {
        pos: [0.0, 300.0, 0.0],
        weight: 1.0,
    }])
    .unwrap();
    m.load_place(rig_place(sp)).unwrap();
    let t0 = Instant::now();
    while m.status().state == State::Loading {
        assert!(t0.elapsed() < Duration::from_secs(600), "no Ready");
        std::thread::sleep(Duration::from_millis(2));
    }
    m
}

fn cores(m: &Formula) -> Vec<Core> {
    let mut c = Vec::new();
    m.cores([0.0, 300.0, 0.0], 8000.0, &mut c);
    c
}

#[test]
fn dynamic_thermals_born_on_rig_place_deterministic() {
    let mut m = formula(true, &preset_obj("strong"), 25.0);
    assert_eq!(m.status().state, State::Ready, "{}", m.status().reason);
    for t in [10.0, 600.0, 3600.0] {
        m.advance_to(t).unwrap();
        let c = cores(&m);
        assert!(c.len() > 20, "t={t}: {} cores", c.len());
        // динамические: не статичные (флаг 1), живые, с сильным подъёмом сильного дня
        assert!(c.iter().all(|k| k.flags as u8 & 1 == 0 && k.w > 0.0));
        assert!(c.iter().any(|k| k.w > 2.0), "t={t}: no strong thermals");
    }
}

#[test]
fn dynamic_thermals_weak_day_weaker_than_strong() {
    let top = |name: &str| {
        let mut m = formula(true, &preset_obj(name), 25.0);
        m.advance_to(600.0).unwrap();
        cores(&m).iter().map(|k| k.w).fold(0.0f32, f32::max)
    };
    let (weak, strong) = (top("weak"), top("strong"));
    assert!(weak > 0.0 && strong > weak, "weak {weak}, strong {strong}");
}

#[test]
fn dynamic_thermals_background_first_snapshot_appears() {
    // игровой режим: первый набор - в фоне; в кадрах `advance_to` ядра появляются за секунды
    let mut m = formula(false, &preset_obj("strong"), 25.0);
    let t0 = Instant::now();
    let mut t = 0.0;
    while cores(&m).is_empty() {
        assert!(
            t0.elapsed() < Duration::from_secs(60),
            "no thermals in 60 s"
        );
        t += 0.016;
        m.advance_to(t).unwrap();
        std::thread::sleep(Duration::from_millis(16));
    }
}

#[test]
fn dynamic_thermals_place_not_25m_fails_but_weather_answers() {
    // шаг 100 м поле не принимает: Failed с причиной, а не «тихо без термиков»; погода и опросы
    // слагаемых при Failed отвечают (W1: запасной путь)
    let mut m = formula(true, &preset_obj("strong"), 100.0);
    let s = m.status();
    assert_eq!(s.state, State::Failed);
    assert!(s.reason.contains("25 m"), "reason: {}", s.reason);
    m.advance_to(10.0).unwrap();
    assert!(m.weather_json().len() > 100, "weather is empty in Failed");
}
