//! Контрактные тесты W4/W5 (T5, T6). Набор `suite` принимает окружение модели — фабрику, конфиги и
//! место, — один и тот же набор идёт на `Calm` и на `Formula` (RW-6j: настоящие конфиги игры,
//! синтетика W8, детерминированный режим, малая область; загрузка `Formula` — фон, тесты ждут
//! `Ready` после `load_place`).
use dp_air::*;
use std::time::{Duration, Instant};

/// Окружение набора: фабрика модели, конфиги для `configure`, место для `load_place`.
struct Env {
    make: Box<dyn Fn() -> Box<dyn AirModel>>,
    configs: Configs,
    place: fn() -> Place,
}

type Make<'a> = &'a Env;

/// Ждёт конца загрузки (`Loading`); `Failed` — провал теста.
fn settle(m: &dyn AirModel) {
    let t0 = Instant::now();
    loop {
        match m.status().state {
            State::Loading => {}
            State::Failed => panic!("model failed: {}", m.status().reason),
            _ => return,
        }
        assert!(t0.elapsed() < Duration::from_secs(900), "Loading too long");
        std::thread::sleep(Duration::from_millis(2));
    }
}

const HEADER: &str = r#"{"version":1,"loc":{"id":"t","center_lat":50.0,"center_lon":86.0,
"utc_offset_h":7.0,"month":7,"day":1},"grid":{"origin_x":-100,"origin_z":-100,"spacing":50,
"width":5,"height":4},"surface_classes":{"grass":1,"rock":2},"start_sites":[{"x":0,"z":0,"h_msl":10}]}"#;

fn tiny_place() -> Place {
    let h = PlaceHeader::from_json(HEADER).unwrap();
    let n = h.cells();
    Place::new(h, vec![100.0; n], vec![0; n], vec![1; n], vec![0.5; n]).unwrap()
}

fn forecast_cond() -> Conditions {
    Conditions::from_json(
        r#"{"forecast":{"temperature_c":20,"wind_speed_kmh":10,"wind_from_deg":270,"sky":"clear"},
"start_hour":12,"speed":1,"quantum_h":0.5,"wind_ref":null,"overrides":{},"blend_s":null,"rebuild":false}"#,
    )
    .unwrap()
}

fn code<T>(r: Result<T, Error>) -> Code {
    match r {
        Ok(_) => Code::Ok,
        Err(e) => e.code,
    }
}

fn ready(make: Make) -> Box<dyn AirModel> {
    let mut m = (make.make)();
    m.configure(&make.configs, 1).unwrap();
    m.load_place((make.place)()).unwrap();
    settle(&*m);
    m
}

fn all_finite(v: &[[f32; 4]]) -> bool {
    v.iter().flatten().all(|x| x.is_finite())
}

fn suite(make: Make) {
    empty_state(make);
    empty_and_mismatched_batches(make);
    non_finite_points(make);
    point_outside_place(make);
    commands_before_place(make);
    reload_place(make);
    same_t_same_answer(make);
    advance_only_forward(make);
    start_at_defined(make);
    multiple_focuses(make);
    bad_input_keeps_state(make);
    concurrent_queries(make);
    cores_lift_invariant(make);
    out_is_replaced(make);
}

fn empty_state(make: Make) {
    let m = (make.make)();
    let s = m.status();
    assert_eq!(s.state, State::Empty);
    let mut out = [[1.0f32; 4]; 2];
    m.sample_many(&[[0.0; 3]; 2], SampleMode::Full, &mut out);
    assert!(all_finite(&out));
    assert!(m.cloudbase_msl().is_finite());
    assert!(m.sun_state().iter().all(|v| v.is_finite()));
    assert!(m.cloud_raster().is_none() || m.cloud_raster().unwrap().version < u64::MAX);
}

fn empty_and_mismatched_batches(make: Make) {
    let m = ready(make);
    m.sample_many(&[], SampleMode::Mean, &mut []);
    // out длиннее pts: хвост не трогается
    let mut out = [[7.0f32; 4]; 3];
    m.sample_many(&[[0.0, 100.0, 0.0]], SampleMode::Full, &mut out);
    assert!(all_finite(&out[..1]));
    assert_eq!(out[1], [7.0; 4]);
    assert_eq!(out[2], [7.0; 4]);
    // pts длиннее out: паники нет, пишется min
    let mut out1 = [[7.0f32; 4]; 1];
    m.sample_many(&[[0.0; 3]; 5], SampleMode::Full, &mut out1);
    let mut d = [9.0f32; 4];
    m.cloud_density_many(&[[0.0; 3]; 2], &mut d);
    assert_eq!(d[2], 9.0);
    let mut bw = [[5.0f32; 2]; 3];
    m.background_wind(&[10.0], &mut bw);
    assert_eq!(bw[1], [5.0; 2]);
    m.background_wind(&[], &mut []);
}

fn non_finite_points(make: Make) {
    let m = ready(make);
    let bad = f32::NAN;
    let pts = [
        [bad, 0.0, 0.0],
        [0.0, f32::INFINITY, 0.0],
        [0.0, 0.0, f32::NEG_INFINITY],
        [0.0, 100.0, 0.0],
    ];
    let mut out = [[1.0f32; 4]; 4];
    m.sample_many(&pts, SampleMode::Full, &mut out);
    assert!(all_finite(&out));
    for o in &out[..3] {
        assert_eq!(*o, [0.0; 4], "NaN/inf point must give zeros");
    }
    let mut dens = [1.0f32; 4];
    m.cloud_density_many(&pts, &mut dens);
    assert!(dens.iter().all(|v| v.is_finite()));
    let mut bw = [[1.0f32; 2]; 2];
    m.background_wind(&[bad, f32::INFINITY], &mut bw);
    assert!(bw.iter().flatten().all(|v| v.is_finite()));
    let d = m.decompose([bad, 0.0, 0.0]);
    assert!(d.total.iter().all(|v| v.is_finite()));
}

fn point_outside_place(make: Make) {
    let m = ready(make);
    let pts = [[1.0e6, 50.0, -1.0e6], [-5.0e4, 3000.0, 4.0e4]];
    let mut out = [[0.0f32; 4]; 2];
    m.sample_many(&pts, SampleMode::Full, &mut out);
    assert!(all_finite(&out));
    assert!(out.iter().all(|o| o[3] >= 0.0), "sigma >= 0");
}

fn commands_before_place(make: Make) {
    let mut m = (make.make)();
    // v2: настройки до места запоминаются — Ok; время без места — NoPlace
    assert_eq!(code(m.set_conditions(&forecast_cond())), Code::Ok);
    assert_eq!(code(m.set_focuses(&[])), Code::Ok);
    assert_eq!(code(m.set_static_thermals(&[], 0)), Code::Ok);
    m.set_sun_direction(Some([0.0, 1.0, 0.0]));
    assert_eq!(code(m.advance_to(1.0)), Code::NoPlace);
    assert_eq!(code(m.start_at(1.0)), Code::NoPlace);
    m.unload_place(); // без места — не ошибка
    assert_eq!(m.status().state, State::Empty);
    assert_eq!(code(m.configure(&make.configs, 5)), Code::Ok);
    // запомненное применяется при загрузке: место грузится и после настроек
    m.load_place((make.place)()).unwrap();
    settle(&*m);
    assert_eq!(m.status().state, State::Ready);
    // unload сбрасывает место и время: снова NoPlace
    m.advance_to(4.0).unwrap();
    m.unload_place();
    assert_eq!(code(m.advance_to(5.0)), Code::NoPlace);
    assert_eq!(m.status().time_s, 0.0);
    // плохой вход отвергается и до места
    assert_eq!(
        code(m.set_static_thermals(&[[f32::NAN, 0.0, 1.0, 1.0]], 0)),
        Code::BadInput
    );
}

/// v2: `cores`/`clouds`/`wave_crests` заменяют `out` (очищают), а не дописывают.
fn out_is_replaced(make: Make) {
    let m = ready(make);
    let mut cores = vec![Core::default(); 3];
    m.cores([0.0; 3], 1000.0, &mut cores);
    let n = cores.len();
    m.cores([0.0; 3], 1000.0, &mut cores);
    assert_eq!(cores.len(), n, "second call must not append");
    let mut clouds = vec![Cloud::default(); 3];
    m.clouds([0.0; 3], 1000.0, &mut clouds);
    let n = clouds.len();
    m.clouds([0.0; 3], 1000.0, &mut clouds);
    assert_eq!(clouds.len(), n);
    let mut crests = vec![Crest::default(); 3];
    m.wave_crests([0.0; 2], 1000.0, 0.0, 10.0, &mut crests);
    let n = crests.len();
    m.wave_crests([0.0; 2], 1000.0, 0.0, 10.0, &mut crests);
    assert_eq!(crests.len(), n);
    if n == 0 {
        assert!(crests.is_empty());
    }
}

fn reload_place(make: Make) {
    let mut m = ready(make);
    m.advance_to(10.0).unwrap();
    m.load_place((make.place)()).unwrap();
    settle(&*m);
    assert_eq!(m.status().state, State::Ready);
    assert_eq!(m.status().time_s, 0.0, "reload starts from zero");
    m.unload_place();
    assert_eq!(m.status().state, State::Empty);
    m.load_place((make.place)()).unwrap();
    settle(&*m);
    assert_eq!(m.status().state, State::Ready);
}

fn same_t_same_answer(make: Make) {
    let mut m = ready(make);
    m.set_conditions(&forecast_cond()).unwrap();
    m.advance_to(5.0).unwrap();
    let pts: Vec<[f32; 3]> = (0..50).map(|i| [i as f32 * 7.0, 200.0, i as f32]).collect();
    let (mut a, mut b) = (vec![[0.0f32; 4]; 50], vec![[1.0f32; 4]; 50]);
    m.sample_many(&pts, SampleMode::Full, &mut a);
    m.sample_many(&pts, SampleMode::Full, &mut b);
    assert_eq!(a, b);
    m.advance_to(5.0).unwrap(); // тот же t — Ok и без изменений
    m.sample_many(&pts, SampleMode::Full, &mut b);
    assert_eq!(a, b);
}

fn advance_only_forward(make: Make) {
    let mut m = ready(make);
    m.advance_to(10.0).unwrap();
    assert_eq!(code(m.advance_to(10.0)), Code::Ok);
    assert_eq!(code(m.advance_to(9.0)), Code::BadInput);
    assert_eq!(m.status().time_s, 10.0);
    assert_eq!(code(m.advance_to(f64::NAN)), Code::BadInput);
    assert_eq!(code(m.advance_to(f64::INFINITY)), Code::BadInput);
    assert_eq!(code(m.advance_to(-1.0)), Code::BadInput);
    assert_eq!(code(m.start_at(-1.0)), Code::BadInput);
    m.advance_to(11.0).unwrap();
    assert_eq!(m.status().time_s, 11.0);
}

fn start_at_defined(make: Make) {
    let mut m = (make.make)();
    assert_eq!(code(m.start_at(100.0)), Code::NoPlace); // до Ready — определённый ответ
    let mut m = ready(make);
    assert_eq!(code(m.start_at(f64::NAN)), Code::BadInput);
    m.start_at(100.0).unwrap();
    assert_eq!(m.status().time_s, 100.0);
    m.advance_to(101.0).unwrap();
}

fn multiple_focuses(make: Make) {
    let mut m = ready(make);
    let f = |x: f32, w: f32| Focus {
        pos: [x, 100.0, 0.0],
        weight: w,
    };
    m.set_focuses(&[f(0.0, 1.0), f(500.0, 0.5), f(-500.0, 2.0)])
        .unwrap();
    m.set_focuses(&[]).unwrap();
    m.set_focuses(&[f(0.0, 0.0)]).unwrap();
    // много фокусов: крупные и мелкие веса
    let many: Vec<Focus> = (0..64)
        .map(|i| f(i as f32 * 100.0, 1e-3 + i as f32))
        .collect();
    m.set_focuses(&many).unwrap();
    let mut out = [[0.0f32; 4]; 1];
    m.sample_many(&[[0.0, 100.0, 0.0]], SampleMode::Full, &mut out);
    assert!(all_finite(&out));
}

fn bad_input_keeps_state(make: Make) {
    let mut m = ready(make);
    m.advance_to(3.0).unwrap();
    assert_eq!(
        code(m.set_focuses(&[Focus {
            pos: [f32::NAN; 3],
            weight: 1.0
        }])),
        Code::BadInput
    );
    assert_eq!(
        code(m.set_focuses(&[Focus {
            pos: [0.0; 3],
            weight: -1.0
        }])),
        Code::BadInput
    );
    assert_eq!(
        code(m.set_static_thermals(&[[0.0, 0.0, f32::NAN, 1.0]], 0)),
        Code::BadInput
    );
    let bad = Configs::new(vec![("wind.json".into(), "{not json".into())]);
    assert_eq!(code(m.configure(&bad, 1)), Code::BadInput);
    assert_eq!(m.status().state, State::Ready);
    assert_eq!(m.status().time_s, 3.0);
    let e = m.advance_to(1.0).unwrap_err();
    assert!(!e.msg.is_empty(), "error text for last_error()");
    m.set_static_thermals(&[[0.0, 0.0, 100.0, 2.0]], 1).unwrap();
}

fn concurrent_queries(make: Make) {
    let mut m = ready(make);
    m.advance_to(2.0).unwrap();
    let m: &dyn AirModel = &*m;
    let pts: Vec<[f32; 3]> = (0..200).map(|i| [i as f32, 300.0, -(i as f32)]).collect();
    let mut want = vec![[0.0f32; 4]; 200];
    m.sample_many(&pts, SampleMode::Full, &mut want);
    std::thread::scope(|s| {
        for _ in 0..4 {
            s.spawn(|| {
                for _ in 0..20 {
                    let mut got = vec![[0.0f32; 4]; 200];
                    m.sample_many(&pts, SampleMode::Full, &mut got);
                    assert_eq!(got, want);
                    let _ = m.status();
                    let mut cs = Vec::new();
                    m.cores([0.0; 3], 1000.0, &mut cs);
                }
            });
        }
    });
}

/// T6 / W6 v3: у ядра без флага Cb (бит 2) и с w ≥ 1,5 м/с средний `vy` по `sample_many` в круге `0,5·radius`
/// на высоте `(y_src + top)/2` положителен и больше среднего `vy` в кольце 2–3·radius на той же
/// высоте; id — целое в [0, 2^24). На `Calm` и `Formula` (до RW-10) ядер нет — проверка пуста.
fn cores_lift_invariant(make: Make) {
    let m = ready(make);
    let mut cores = Vec::new();
    m.cores([0.0, 0.0, 0.0], 20_000.0, &mut cores);
    for c in &cores {
        assert!(
            c.id.fract() == 0.0 && (0.0..16_777_216.0).contains(&c.id),
            "core id {} must be an integer in [0, 2^24)",
            c.id
        );
        if (c.flags as u32) & 4 != 0 || c.w < 1.5 {
            continue; // Cb и слабые ядра (W6 v3: инвариант — только для w ≥ 1,5 м/с)
        }
        let y = 0.5 * (c.y_src + c.top);
        let mean_vy = |r: f32| {
            let pts: Vec<[f32; 3]> = (0..16)
                .map(|k| {
                    let a = k as f32 * std::f32::consts::TAU / 16.0;
                    [
                        c.x + c.lean_x * (y - c.y_src) + r * a.cos(),
                        y,
                        c.z + c.lean_z * (y - c.y_src) + r * a.sin(),
                    ]
                })
                .collect();
            let mut out = vec![[0.0f32; 4]; pts.len()];
            m.sample_many(&pts, SampleMode::Mean, &mut out);
            out.iter().map(|o| o[1] as f64).sum::<f64>() / out.len() as f64
        };
        let inside = mean_vy(0.5 * c.radius);
        let ring =
            (mean_vy(2.0 * c.radius) + mean_vy(2.5 * c.radius) + mean_vy(3.0 * c.radius)) / 3.0;
        assert!(inside > 0.0, "core {} has mean vy {inside} <= 0", c.id);
        assert!(
            inside > ring,
            "core {}: vy inside {inside} <= ring {ring}",
            c.id
        );
    }
}

#[test]
fn calm_suite() {
    suite(&Env {
        make: Box::new(|| Box::new(Calm::new())),
        configs: Configs::default(),
        place: tiny_place,
    });
}

// ---- Formula (RW-6j) ----

fn collect_configs(dir: &std::path::Path, prefix: &str, out: &mut Vec<(String, String)>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        let name = format!("{prefix}{}", p.file_name().unwrap().to_string_lossy());
        if p.is_dir() {
            collect_configs(&p, &format!("{name}/"), out);
        } else if p.extension().is_some_and(|x| x == "json") {
            out.push((name, std::fs::read_to_string(&p).unwrap()));
        }
    }
}

/// Конфиги игры; `air`: детерминизм, область 7,2 км, tol_scale 5 (критерий игры).
fn formula_configs() -> Configs {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../configs");
    let mut files = Vec::new();
    collect_configs(&root, "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere.json" {
            let mut v: serde_json::Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = true.into();
            v["air"]["domain_l_m"] = 7200.0.into();
            v["air"]["tol_scale"] = 5.0.into();
            v["air"]["threads"] = 4.into();
            v["air"]["timeout_s"] = 600.0.into();
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

/// Синтетика W8 (20 км, сетка 25 м): область сжимается до помещающейся.
fn synthetic_place() -> Place {
    static P: std::sync::OnceLock<Place> = std::sync::OnceLock::new();
    P.get_or_init(|| {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/wind/places/synthetic.json");
        // W5 v8: прогнозу нужна сырая ячейка климата; у синтетики её нет - заголовок без климата
        // (запасные значения), как у синтетических заголовков тестов
        let p = fixtures::read_place(&path).unwrap();
        let mut h = p.header().clone();
        h.loc.climate = None;
        h.loc.climate_lag = None;
        Place::new(
            h,
            p.heights().to_vec(),
            p.water().to_vec(),
            p.cls().to_vec(),
            p.moist().to_vec(),
        )
        .unwrap()
    })
    .clone()
}

#[test]
fn formula_suite() {
    suite(&Env {
        make: Box::new(|| Box::new(Formula::new())),
        configs: formula_configs(),
        place: synthetic_place,
    });
}

#[test]
fn formula_is_send_sync() {
    fn is<T: Send + Sync>() {}
    is::<Formula>();
}

#[test]
fn calm_is_send_sync() {
    fn is<T: Send + Sync>() {}
    is::<Calm>();
}

#[test]
fn calm_ready_after_load_is_immediate() {
    let mut m = Calm::new();
    assert_eq!(m.status().state, State::Empty);
    m.load_place(tiny_place()).unwrap();
    let s = m.status();
    assert_eq!((s.state, s.progress), (State::Ready, 1.0));
    let mut out = [[1.0f32; 4]; 3];
    m.sample_many(&[[1.0, 2.0, 3.0]; 3], SampleMode::Full, &mut out);
    assert_eq!(out, [[0.0; 4]; 3]);
    assert!(m.cloud_raster().is_none());
    assert!(m.debug_raster("x").is_none());
    assert!(m.debug_raster_names().is_empty());
    let d = m.decompose([0.0; 3]);
    assert!(d.names.is_empty() && d.total == [0.0; 4]);
    assert_eq!(m.weather_version(), (0, 0));
}

#[test]
fn api_version_matches_contract_header() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../docs/contracts/rust-wind.md"
    );
    let text = std::fs::read_to_string(path).expect("contract file");
    let line = text
        .lines()
        .find(|l| l.starts_with("## W2."))
        .expect("W2 header");
    let v: u32 = line
        .rsplit_once("(v")
        .and_then(|(_, r)| r.strip_suffix(')'))
        .and_then(|r| r.parse().ok())
        .unwrap_or_else(|| panic!("no version in header: {line}"));
    assert_eq!(API_VERSION, v);
}

#[test]
fn codes_match_w1() {
    assert_eq!(
        [Code::Ok, Code::BadInput, Code::NoPlace, Code::NotReady].map(Code::as_int),
        [0, 1, 2, 3]
    );
    assert_eq!(
        [State::Empty, State::Loading, State::Ready, State::Failed].map(State::as_int),
        [0, 1, 2, 3]
    );
}

// ---- разбор W5 ----

fn hdr(edit: impl Fn(&str) -> String) -> Result<PlaceHeader, Error> {
    PlaceHeader::from_json(&edit(HEADER))
}

#[test]
fn header_parses() {
    let h = PlaceHeader::from_json(HEADER).unwrap();
    assert_eq!(
        (h.version, h.grid.width, h.grid.height, h.cells()),
        (1, 5, 4, 20)
    );
    assert_eq!(h.loc.id, "t");
    assert_eq!(h.surface_classes["rock"], 2);
    assert_eq!(h.start_sites.len(), 1);
}

#[test]
fn header_rejects_bad() {
    for (what, f) in [
        (
            "version",
            hdr(|s| s.replace("\"version\":1", "\"version\":2")),
        ),
        ("width 0", hdr(|s| s.replace("\"width\":5", "\"width\":0"))),
        (
            "spacing",
            hdr(|s| s.replace("\"spacing\":50", "\"spacing\":-1")),
        ),
        ("month", hdr(|s| s.replace("\"month\":7", "\"month\":13"))),
        ("missing grid", hdr(|s| s.replace("\"grid\"", "\"gridx\""))),
        ("not json", hdr(|_| "{".into())),
    ] {
        assert_eq!(code(f), Code::BadInput, "{what}");
    }
}

#[test]
fn place_checks_lengths_and_nan() {
    let h = || PlaceHeader::from_json(HEADER).unwrap();
    let n = 20;
    let ok = |hs: Vec<f32>, w: Vec<u8>, c: Vec<u8>, m: Vec<f32>| Place::new(h(), hs, w, c, m);
    assert!(ok(vec![0.0; n], vec![0; n], vec![0; n], vec![0.0; n]).is_ok());
    assert_eq!(
        code(ok(vec![0.0; n - 1], vec![0; n], vec![0; n], vec![0.0; n])),
        Code::BadInput
    );
    assert_eq!(
        code(ok(vec![0.0; n], vec![0; n + 1], vec![0; n], vec![0.0; n])),
        Code::BadInput
    );
    assert_eq!(
        code(ok(vec![0.0; n], vec![0; n], vec![0; 1], vec![0.0; n])),
        Code::BadInput
    );
    assert_eq!(
        code(ok(vec![0.0; n], vec![0; n], vec![0; n], vec![])),
        Code::BadInput
    );
    let mut hs = vec![0.0f32; n];
    hs[7] = f32::NAN;
    assert_eq!(
        code(ok(hs, vec![0; n], vec![0; n], vec![0.0; n])),
        Code::BadInput
    );
    assert_eq!(
        code(ok(vec![0.0; n], vec![2; n], vec![0; n], vec![0.0; n])),
        Code::BadInput
    );
}

#[test]
fn configs_pairs_and_unknown_keys() {
    let mut m = Calm::new();
    let ok = Configs::new(vec![
        (
            "wind.json".into(),
            r#"{"wind":{"a":1},"some_unknown_key":true}"#.into(),
        ),
        ("empty.json".into(), "{}".into()),
    ]);
    assert_eq!(code(m.configure(&ok, 7)), Code::Ok);
    let bad = Configs::new(vec![("x.json".into(), "".into())]);
    let e = m.configure(&bad, 7).unwrap_err();
    assert_eq!(e.code, Code::BadInput);
    assert!(e.msg.contains("x.json"));
}

const FC: &str =
    r#""forecast":{"temperature_c":20,"wind_speed_kmh":10,"wind_from_deg":270,"sky":"clear"}"#;

fn cond(body: &str) -> Result<Conditions, Error> {
    Conditions::from_json(&format!("{{{body}}}"))
}

#[test]
fn conditions_forecast_ok() {
    let c = cond(&format!(
        r#"{FC},"start_hour":9.5,"speed":2,"quantum_h":0.25,"wind_ref":{{"ref_msl":1500,"gain_per_km":0.5}},"overrides":{{"thermal_spacing_m":900}},"blend_s":30,"rebuild":true"#
    ))
    .unwrap();
    assert!(c.rebuild && c.speed == 2.0 && c.blend_s == Some(30.0));
    match c.source {
        Source::Forecast {
            wind_ref,
            overrides,
            quantum_h,
            ..
        } => {
            assert!(wind_ref.is_some() && overrides.len() == 1 && quantum_h == 0.25)
        }
        _ => panic!("expected forecast"),
    }
}

#[test]
fn conditions_preset_ok() {
    let c = cond(r#""preset":"weather/medium","start_hour":12,"speed":1"#).unwrap();
    assert!(matches!(c.source, Source::Preset(v) if v == "weather/medium"));
    let c = cond(r#""preset":{"a":1},"start_hour":12,"speed":1,"blend_s":null,"rebuild":false"#)
        .unwrap();
    assert!(matches!(c.source, Source::Preset(v) if v.is_object()));
}

#[test]
fn conditions_reject_bad() {
    let base = r#""start_hour":12,"speed":1"#;
    let fc_ok = format!(r#"{FC},"quantum_h":0.5,{base}"#);
    assert!(cond(&fc_ok).is_ok());
    for (what, body) in [
        ("both", format!(r#"{fc_ok},"preset":"x""#)),
        ("neither", base.to_string()),
        ("stray key", format!(r#"{fc_ok},"bogus":1"#)),
        (
            "stray in forecast",
            format!(
                r#""forecast":{{"temperature_c":1,"wind_speed_kmh":1,"wind_from_deg":1,"sky":"a","x":1}},"quantum_h":1,{base}"#
            ),
        ),
        (
            "preset with forecast key",
            format!(r#""preset":"x","quantum_h":1,{base}"#),
        ),
        (
            "missing start_hour",
            format!(r#"{FC},"quantum_h":0.5,"speed":1"#),
        ),
        ("missing quantum_h", format!(r#"{FC},{base}"#)),
        (
            "speed 0",
            format!(r#"{FC},"quantum_h":0.5,"start_hour":1,"speed":0"#),
        ),
        ("preset type", format!(r#""preset":5,{base}"#)),
    ] {
        assert_eq!(code(cond(&body)), Code::BadInput, "{what}");
    }
    assert_eq!(code(Conditions::from_json("[]")), Code::BadInput);
}

#[test]
fn calm_clears_out_vecs() {
    let m = Calm::new();
    let mut cores = vec![Core::default(); 3];
    m.cores([0.0; 3], 10.0, &mut cores);
    assert!(cores.is_empty());
    let mut clouds = vec![Cloud::default(); 3];
    m.clouds([0.0; 3], 10.0, &mut clouds);
    assert!(clouds.is_empty());
    let mut crests = vec![Crest::default(); 3];
    m.wave_crests([0.0; 2], 10.0, 0.0, 1.0, &mut crests);
    assert!(crests.is_empty());
}

#[test]
fn records_flatten_in_w6_order() {
    let c = Core {
        id: 1.0,
        storm: 14.0,
        ..Core::default()
    };
    let one = [c];
    let f = as_f32s(&one);
    assert_eq!(f.len(), 15);
    assert_eq!((f[0], f[14]), (1.0, 14.0));
    let (cl, cr) = ([Cloud::default(); 2], [Crest::default(); 3]);
    assert_eq!(as_f32s(&cl).len(), 20);
    assert_eq!(as_f32s(&cr).len(), 12);
}

#[test]
fn conditions_inflow_mode() {
    let base = r#""preset":"weather/medium","start_hour":12,"speed":1"#;
    assert_eq!(cond(base).unwrap().inflow_mode, InflowMode::Start);
    for (v, want) in [("start", InflowMode::Start), ("inflow", InflowMode::Inflow)] {
        let c = cond(&format!(r#"{base},"inflow_mode":"{v}""#)).unwrap();
        assert_eq!(c.inflow_mode, want);
    }
    let fc = format!(r#"{FC},"quantum_h":0.5,"start_hour":12,"speed":1,"inflow_mode":"inflow""#);
    assert_eq!(cond(&fc).unwrap().inflow_mode, InflowMode::Inflow);
    for bad in [
        r#""inflow_mode":"warm""#,
        r#""inflow_mode":1"#,
        r#""inflow_mode":"""#,
    ] {
        assert_eq!(
            code(cond(&format!("{base},{bad}"))),
            Code::BadInput,
            "{bad}"
        );
    }
}
