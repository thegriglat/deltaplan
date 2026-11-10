//! RW-8b: каркас суммы ветра (`terms::sum`, `terms::decompose`) — при нулевых слотах опрос
//! побитно как прежний `sample_point` (копия старой функции здесь), `decompose` по именам W7 с
//! инвариантами, порядок суммы и ограничители на слотах-пробниках, полоса края `a < 1`.
use dp_air::field::field_set::FieldSet;
use dp_air::field::runtime::{Faults, RtCfg, ground_height};
use dp_air::field::solved::parse_solved;
use dp_air::terms::{
    self, Analytic, AnalyticMean, AnalyticTurb, Ctx, Extra, ExtraOut, Rec, Slots, Terms, Thermal,
    ThermalOut, Turb, TurbMean, TurbOut, WeatherView,
};
use dp_air::{AirModel, Conditions, Configs, Focus, Formula, Place, SampleMode, State};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

const NO_WIN: Faults = Faults {
    coarse: false,
    fail_pass: None,
    no_phase: false,
    no_windows: true,
};

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

/// Конфиги игры в детерминированном режиме, малая область.
fn configs() -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = serde_json::json!(true);
            v["air"]["domain_l_m"] = serde_json::json!(7200.0);
            v["air"]["threads"] = serde_json::json!(4);
            v["air"]["tol_scale"] = serde_json::json!(5.0);
            v["air_model"]["edge_blend_cells"] = serde_json::json!(1.0);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

fn island_place() -> Place {
    let header = r#"{"version":1,"loc":{"id":"training_island","center_lat":43.2,"center_lon":34.0,
"utc_offset_h":2.0,"month":7,"day":15},"model_hash":"terms-sum-1","grid":{"origin_x":-10000,"origin_z":-10000,"spacing":25,
"width":801,"height":801},"surface_classes":{"grass":1},
"start_sites":[{"x":3510.0,"z":-1510.0,"h_msl":100.0}]}"#;
    let h = dp_air::PlaceHeader::from_json(header).unwrap();
    let n = h.cells();
    Place::new(h, vec![100.0; n], vec![0; n], vec![1; n], vec![0.5; n]).unwrap()
}

fn landing_cond() -> Conditions {
    Conditions::from_json(
        r#"{"forecast":{"temperature_c":22,"wind_speed_kmh":3.6,"wind_from_deg":270,"sky":"clear"},
"quantum_h":1,"start_hour":9,"speed":1,"blend_s":null,"rebuild":false}"#,
    )
    .unwrap()
}

fn focus() -> Focus {
    Focus {
        pos: [3510.0, 110.0, -1510.0],
        weight: 1.0,
    }
}

/// Рабочая `Formula` с посчитанным полем: место, условия, фокус, поля; ждёт `Ready` с полем.
fn ready_model(windows: bool) -> (Formula, Place) {
    // поле считается один раз на вариант (с окнами/без), дальше — из кеша: шесть тестов
    // одновременно в debug не успевают посчитать его за таймаут
    static ONE_AT_A_TIME: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _g = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    let dir = std::env::temp_dir().join(format!("dp-air-terms-sum-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let pl = island_place();
    let mut m = Formula::new();
    if !windows {
        m = m.with_faults(NO_WIN);
    }
    m.configure(&configs(), 1).unwrap();
    m.set_cache_dir(dir.to_str().unwrap()).unwrap();
    m.set_conditions(&landing_cond()).unwrap();
    m.set_focuses(&[focus()]).unwrap();
    m.load_place(pl.clone()).unwrap();
    wait_field(&mut m);
    (m, pl)
}

fn wait_field(m: &mut Formula) {
    let t0 = Instant::now();
    loop {
        m.poll();
        if m.status().state == State::Ready && m.level_count() > 0 {
            return;
        }
        assert_ne!(m.status().state, State::Failed, "{}", m.status().reason);
        assert!(t0.elapsed() < Duration::from_secs(900), "no field in 900 s");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// Прежний `Formula::sample_point` (до RW-8b), копия для побитного сравнения.
fn old_sample_point(fs: &FieldSet, place: &Place, p: [f32; 3]) -> [f32; 4] {
    if !p.iter().all(|v| v.is_finite()) || !fs.is_active() {
        return [0.0; 4];
    }
    let g = ground_height(place, p[0], p[2]);
    let v = fs.sample(p, g);
    let f = |x: f64| {
        let y = x as f32;
        if y.is_finite() { y } else { 0.0 }
    };
    [f(v.v[0]), f(v.v[1]), f(v.v[2]), 0.0]
}

/// Набор уровней из выдачи поля `Formula` (те же уровни, что у опросов).
fn field_set_of(m: &Formula, edge_cells: Option<f64>) -> FieldSet {
    let e = m.field_export();
    let b = parse_solved(&e.header_json, &e.data).unwrap();
    let rt = RtCfg::from_configs(&configs()).unwrap();
    let mut fs = FieldSet::new(rt.limits, edge_cells.unwrap_or(rt.edge_blend_cells));
    fs.set_field(b.levels, 0.0);
    fs
}

/// 1000 точек: окна у площадки, область, высоты от «под землёй» до 3 км, далеко вне области,
/// NaN/inf. Детерминированный генератор.
fn thousand(pl: &Place) -> Vec<[f32; 3]> {
    let mut s = 0x9E37_79B9_7F4A_7C15u64;
    let mut rnd = move || {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        (s >> 11) as f64 / (1u64 << 53) as f64
    };
    let mut v = Vec::new();
    for i in 0..1000 {
        let (x, z) = match i % 4 {
            0 => (
                3510.0 + 400.0 * (rnd() - 0.5),
                -1510.0 + 400.0 * (rnd() - 0.5),
            ),
            1 => (
                3510.0 + 7000.0 * (rnd() - 0.5),
                -1510.0 + 7000.0 * (rnd() - 0.5),
            ),
            2 => (-9000.0 + 18000.0 * rnd(), -9000.0 + 18000.0 * rnd()),
            _ => (-3.0e4 + 6.0e4 * rnd(), -3.0e4 + 6.0e4 * rnd()),
        };
        let g = ground_height(pl, x as f32, z as f32);
        let dy = match i % 5 {
            0 => -50.0 + 52.0 * rnd(),
            1 => 2.0 + 30.0 * rnd(),
            2 => 30.0 + 300.0 * rnd(),
            _ => 300.0 + 2700.0 * rnd(),
        };
        v.push([x as f32, g + dy as f32, z as f32]);
    }
    v[10] = [f32::NAN, 100.0, 0.0];
    v[11] = [0.0, f32::INFINITY, 0.0];
    v[12] = [0.0, 100.0, f32::NEG_INFINITY];
    v
}

/// (1) Нулевые слоты: `sample_many` FULL и MEAN побитно = прежнему `sample_point` в 1000 точках
/// поля, окон и вне области (и NaN/inf — нули).
#[test]
fn zero_slots_bit_for_bit_like_old_sample_point() {
    let (m, pl) = ready_model(true);
    let fs = field_set_of(&m, None);
    let pts = thousand(&pl);
    let want: Vec<[f32; 4]> = pts.iter().map(|p| old_sample_point(&fs, &pl, *p)).collect();
    assert!(want.iter().flatten().any(|x| *x != 0.0), "поле не нулевое");
    assert!(
        want.iter().filter(|w| w.iter().all(|x| *x == 0.0)).count() > 50,
        "есть точки вне области"
    );
    // Аналитика (RW-9) активна с configure: прежний опрос = слагаемое `field` разложения.
    for (p, w) in pts.iter().zip(&want) {
        let d = m.decompose(*p);
        assert_eq!(
            d.vel[0].map(f32::to_bits),
            [w[0], w[1], w[2]].map(f32::to_bits),
            "{p:?}"
        );
    }
}

const W7: [&str; 9] = [
    "field", "analytic", "ridge", "thermal", "storm", "wave", "cloud", "turb", "gust",
];

/// (2) `decompose`: имена W7 и длины, `total` = `sample(FULL)` побитно, `Σ vel = total.xyz` ±1e-4;
/// без поля и места — нули с теми же именами.
#[test]
fn decompose_names_and_invariants() {
    let (m, pl) = ready_model(true);
    let pts = thousand(&pl);
    let mut full = vec![[0.0f32; 4]; pts.len()];
    m.sample_many(&pts, SampleMode::Full, &mut full);
    let mut nonzero = 0;
    for (p, f) in pts.iter().zip(&full) {
        let d = m.decompose(*p);
        assert_eq!(d.names, W7);
        assert_eq!((d.vel.len(), d.sigma.len()), (9, 9));
        assert_eq!(
            d.total.map(f32::to_bits),
            f.map(f32::to_bits),
            "total = sample(FULL) побитно в {p:?}"
        );
        let s: [f32; 3] = std::array::from_fn(|q| d.vel.iter().map(|v| v[q]).sum());
        for q in 0..3 {
            assert!(
                (s[q] - d.total[q]).abs() <= 1e-4,
                "Σ vel в {p:?}: {s:?} {:?}",
                d.total
            );
            assert!(d.total[q].is_finite() && d.vel.iter().all(|v| v[q].is_finite()));
        }
        if d.total.iter().any(|x| *x != 0.0) {
            nonzero += 1;
        }
    }
    assert!(nonzero > 100);
    // место не загружено: нули, имена на месте
    let e = Formula::new().decompose([1.0, 2.0, 3.0]);
    assert_eq!(e.names, W7);
    assert_eq!(e.total, [0.0; 4]);
    assert!(e.vel.iter().all(|v| *v == [0.0; 3]));
}

/// (3) W1: NaN/inf и пустая модель — конечные нули, пачки разной длины не падают.
#[test]
fn nan_and_empty_model_are_finite_zero() {
    let m = Formula::new();
    let pts = [[f32::NAN, 0.0, 0.0], [1.0, 2.0, 3.0]];
    let mut out = [[7.0f32; 4]; 3];
    m.sample_many(&pts, SampleMode::Full, &mut out);
    assert_eq!(out[0], [0.0; 4]);
    assert_eq!(out[1], [0.0; 4]);
    assert_eq!(out[2], [7.0; 4], "лишнее не трогается");
    let (m, _) = ready_model(false);
    let bad = [
        [f32::NAN; 3],
        [f32::INFINITY, 1.0, 1.0],
        [1.0, f32::NAN, 1.0],
    ];
    let mut o = [[1.0f32; 4]; 3];
    m.sample_many(&bad, SampleMode::Mean, &mut o);
    assert!(o.iter().all(|v| *v == [0.0; 4]));
    let d = m.decompose([f32::NAN, 0.0, 0.0]);
    assert_eq!((d.names.len(), d.total), (9, [0.0; 4]));
}

// ---------------------------------------------------------------- слоты-пробники

struct An {
    h: f64,
    var: f64,
    rot: f64,
}
impl Analytic for An {
    fn mean(&self, _c: &Ctx) -> Option<AnalyticMean> {
        Some(AnalyticMean {
            h: self.h,
            w_ridge: 0.5,
            w_lee: -0.25,
            ..Default::default()
        })
    }
    fn turb(
        &self,
        _c: &Ctx,
        _m: Option<&AnalyticMean>,
        _t: Option<&ThermalOut>,
    ) -> Option<AnalyticTurb> {
        Some(AnalyticTurb {
            var: self.var,
            rot: self.rot,
        })
    }
    fn gust(&self, _c: &Ctx, amp: f64, _fade: f64) -> [f64; 3] {
        [amp, amp, amp]
    }
}
struct Th;
impl Thermal for Th {
    fn sample(&self, _c: &Ctx) -> Option<ThermalOut> {
        Some(ThermalOut {
            w: 2.0,
            mask: 0.5,
            sigma: 1.0,
            uh: [0.0; 2],
        })
    }
}
struct Ex;
impl Extra for Ex {
    fn flow(&self, _c: &Ctx, _v: [f64; 3]) -> Option<ExtraOut> {
        Some(ExtraOut {
            storm: [1.0, 0.0, 0.0],
            wave: [0.0, 0.5, 0.0],
            cloud: [0.0, 0.0, 1.0],
            sigma_storm: 2.0,
            sigma_rotor: 0.0,
            chaos: 0.5,
        })
    }
    fn chaos_noise(&self, _c: &Ctx) -> [f64; 3] {
        [1.0; 3]
    }
}
struct Tb;
impl Turb for Tb {
    fn mean(&self, _c: &Ctx, _m: Option<&AnalyticMean>) -> Option<TurbMean> {
        None
    }
    fn sigma(&self, _c: &Ctx, _m: &terms::Mid) -> Option<TurbOut> {
        Some(TurbOut {
            s_u: 2.0,
            s_v: 2.0,
            s_w: 1.0,
            n: [1.0, 0.0, 0.0],
            ..Default::default()
        })
    }
}

fn probe_terms(an: An, with_turb: bool) -> Terms {
    let mut t = Terms::default();
    t.wind.set_wind(5.0, 270.0);
    let mut w = serde_json::Map::new();
    w.insert("background_sink_ms".into(), serde_json::json!(-0.5));
    t.weather = WeatherView::new(w);
    t.slots = Slots {
        analytic: Arc::new(an),
        thermal: Arc::new(Th),
        extra: Arc::new(Ex),
        turb: if with_turb {
            Arc::new(Tb)
        } else {
            Slots::new().turb
        },
    };
    t
}

fn close(a: f32, b: f64, what: &str) {
    assert!((f64::from(a) - b).abs() < 1e-5, "{what}: {a} != {b}");
}

/// (4) Порядок суммы без поля (`a = 0`): среднее аналитики → термик с фоном и `fade` → гроза/волна/
/// облако → σ квадратами с ограничителем → шум → бурление в облаке; MEAN без шума, σ та же;
/// запись `Rec` сходится с итогом.
#[test]
fn sum_order_without_field() {
    let pl = island_place();
    let fs = FieldSet::default();
    let p = [0.0f32, 130.0, 0.0]; // рельеф 100 м, agl 30 м, fade 0,5
    for (var, rot, amp) in [(4.0, 0.0, 3.0), (100.0, 0.0, 4.0), (100.0, 6.0, 6.0)] {
        let t = probe_terms(An { h: 3.0, var, rot }, false);
        let wd = t.wind.dir();
        let mut rec = Rec::default();
        let f = terms::sum(&t, &fs, Some(&pl), p, SampleMode::Full, 0.0, Some(&mut rec));
        let m = terms::sum(&t, &fs, Some(&pl), p, SampleMode::Mean, 0.0, None);
        // vy: ridge + lee + 0,5·(−0,5·0,5 + 2) + волна
        let wy = 0.5 - 0.25 + 0.5 * (-0.5 * 0.5 + 2.0) + 0.5;
        close(m[0], wd[0] * 3.0 + 1.0, "mean x");
        close(m[1], wy, "mean y");
        close(m[2], wd[1] * 3.0 + 1.0, "mean z");
        // σ: ex2 = 1 + 4, амплитуда с ограничителем; с бурлением √(amp² + 0,25)
        let sig = (amp * amp + 0.25f64).sqrt();
        close(m[3], sig, "sigma mean");
        close(f[3], sig, "sigma full");
        close(f[0], wd[0] * 3.0 + 1.0 + 0.5 + amp, "full x");
        close(f[1], wy + 0.5 + amp, "full y");
        close(f[2], wd[1] * 3.0 + 1.0 + 0.5 + amp, "full z");
        for q in 0..3 {
            let s: f64 = rec.vel.iter().map(|v| v[q]).sum();
            assert!(
                (s - f64::from(f[q])).abs() < 1e-4,
                "Σ rec {q}: {s} {}",
                f[q]
            );
        }
        close(rec.sigma[terms::T_GUST] as f32, amp, "sigma[gust]");
        close(rec.vel[terms::T_THERMAL][1] as f32, 0.5 * 1.75, "thermal");
    }
}

/// (5) Полоса края `0 < a < 1`: `tv = (a·tv_поля + (1 − a)·tv_ан)·k`, `k = 1/√(a² + (1 − a)²)`,
/// `σ = √(a·σ_u² + (1 − a)·amp²)`; веса `(1 − a)` аналитики — на слоте; запись сходится.
#[test]
fn edge_band_mixes_noise_with_variance_kept() {
    let (m, pl) = ready_model(false);
    // широкая полоса края (10 клеток при 18 клетках области 7,2 км), чтобы нашлась точка со смесью
    let fs = field_set_of(&m, Some(10.0));
    // точка полосы края области: доля поля между 0,2 и 0,8
    let mut found = None;
    'o: for i in -40..40 {
        for j in -40..40 {
            let (x, z) = (3510.0 + 250.0 * i as f32, -1510.0 + 250.0 * j as f32);
            let p = [x, ground_height(&pl, x, z) + 150.0, z];
            let s = fs.sample(p, ground_height(&pl, x, z)).share;
            if (0.2..0.8).contains(&s) {
                found = Some((p, s));
                break 'o;
            }
        }
    }
    let (p, a) = found.expect("полоса края в области");
    let mut t = Terms::default();
    t.wind.set_wind(5.0, 270.0);
    t.slots.analytic = Arc::new(An {
        h: 3.0,
        var: 4.0,
        rot: 0.0,
    });
    t.slots.turb = Arc::new(Tb);
    let mut rec = Rec::default();
    let f = terms::sum(&t, &fs, Some(&pl), p, SampleMode::Full, 0.0, Some(&mut rec));
    let mn = terms::sum(&t, &fs, Some(&pl), p, SampleMode::Mean, 0.0, None);
    let tv: [f64; 3] = std::array::from_fn(|q| f64::from(f[q]) - f64::from(mn[q]));
    // поле: n = (1,0,0), σ_u = 2 (предел 4); вдоль среднего ветра в точке (MEAN)
    let ml = f64::from(mn[0]).hypot(f64::from(mn[2]));
    assert!(ml > 0.3);
    let e = [f64::from(mn[0]) / ml, f64::from(mn[2]) / ml];
    let tf = [e[0] * 2.0, 0.0, e[1] * 2.0];
    let ta = [2.0; 3];
    let k = 1.0 / (a * a + (1.0 - a) * (1.0 - a)).sqrt();
    for q in 0..3 {
        let want = (tf[q] * a + ta[q] * (1.0 - a)) * k;
        assert!((tv[q] - want).abs() < 2e-4, "tv[{q}] {} != {want}", tv[q]);
    }
    let sig = (a * 4.0 + (1.0 - a) * 4.0).sqrt();
    close(f[3], sig, "sigma");
    close(mn[3], sig, "sigma mean");
    for q in 0..3 {
        let s: f64 = rec.vel.iter().map(|v| v[q]).sum();
        assert!((s - f64::from(f[q])).abs() < 1e-4, "Σ rec {q}");
    }
}

/// (6) Опрос по `Focus`/условиям не нужен для нулевых слотов, но публикация `Terms` не ломает
/// `Formula`: `set_conditions`/`set_focuses`/`advance_to`/`start_at` оставляют опрос прежним.
#[test]
fn commands_keep_zero_slot_samples() {
    let (mut m, pl) = ready_model(false);
    let pts = thousand(&pl);
    // слагаемое `field` (аналитика зависит от условий и фокусов — RW-9)
    let fld = |m: &Formula| -> Vec<[u32; 3]> {
        pts.iter()
            .map(|p| m.decompose(*p).vel[0].map(f32::to_bits))
            .collect()
    };
    let before = fld(&m);
    m.set_focuses(&[focus()]).unwrap();
    m.set_static_thermals(&[[0.0, 0.0, 100.0, 2.0]], 0).unwrap();
    m.set_sun_direction(Some([0.0, 1.0, 0.0]));
    m.advance_to(1.0).unwrap();
    assert_eq!(before, fld(&m));
}
