//! RW-10b: термики по клеткам (слот `Thermal`): сверка с эталонами `synth_*`, ядра W6, статичные,
//! профиль, жизненный цикл, фоновое опускание, `start_at(t)` = прогон с 0.
#![allow(clippy::needless_range_loop)]
use dp_air::Configs;
use dp_air::field::field_set::FieldSet;
use dp_air::fixtures::{self, Case, Frame};
use dp_air::terms::thermal::{AtmoThermal, GroundSource};
use dp_air::terms::{self, Terms};
use dp_air::{Conditions, Focus, Place, PlaceHeader};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::Arc;

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

/// Конфиги игры; `patch` правит `atmosphere.json`.
fn configs_with(patch: impl Fn(&mut Value)) -> Arc<Configs> {
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
    Arc::new(Configs::new(files))
}

/// Как `config_overrides` случаев `synth_*`: круг генерации 8 км.
fn configs() -> Arc<Configs> {
    configs_with(|v| v["thermal"]["generation_radius_m"] = serde_json::json!(8000.0))
}

// ---- синтетический мир `atmo_fingerprint.gd` ----

fn syn_height(x: f64, z: f64) -> f64 {
    900.0
        + 350.0 * (x / 3100.0).sin() * (z / 4300.0).cos()
        + 160.0 * ((x + 0.6 * z) / 1700.0).sin()
        + 40.0 * (x / 450.0 - z / 700.0).cos()
}

fn syn_normal(x: f64, z: f64) -> [f32; 3] {
    let e = 15.0;
    let dx = ((syn_height(x + e, z) - syn_height(x - e, z)) / (2.0 * e)) as f32;
    let dz = ((syn_height(x, z + e) - syn_height(x, z - e)) / (2.0 * e)) as f32;
    let l = (dx * dx + 1.0 + dz * dz).sqrt();
    [-dx / l, 1.0 / l, -dz / l]
}

fn syn_surface_k(x: f64, z: f64) -> f64 {
    0.65 + 0.35 * (x / 830.0 + 1.3).sin() * (z / 1170.0 - 0.4).cos()
}

/// `AtmoFingerprint.source_static`.
fn syn_source(x: f64, z: f64) -> f64 {
    let n = syn_normal(x, z);
    let s = {
        let (a, b, c) = (0.3f32, 0.8f32, 0.5f32);
        let l = (a * a + b * b + c * c).sqrt();
        [a / l, b / l, c / l]
    };
    let d = f64::from(n[0] * s[0] + n[1] * s[1] + n[2] * s[2]);
    (syn_surface_k(x, z) * (0.35 + 0.8 * d)).clamp(0.0, 1.0)
}

struct SynGround;
impl GroundSource for SynGround {
    fn height(&self, x: f64, z: f64) -> f64 {
        syn_height(x, z)
    }
    fn source(&self, x: f64, z: f64, _t: f64) -> f64 {
        syn_source(x, z)
    }
}

fn case_path(name: &str) -> PathBuf {
    repo().join(format!("tests/fixtures/wind/cases/{name}.json"))
}

struct Loaded {
    case: Case,
    place: Place,
    data: fixtures::CaseData,
    frames: Vec<Frame>,
}

fn load(name: &str) -> Loaded {
    let p = case_path(name);
    let case = fixtures::read_case(&p).unwrap();
    let place = fixtures::read_place(&case.place_path(&p)).unwrap();
    let data = fixtures::read_case_data(&case, &p).unwrap();
    let frames = fixtures::read_desc(&case, &p).unwrap();
    Loaded {
        case,
        place,
        data,
        frames,
    }
}

fn terms_for(case: &Case, ground: Arc<dyn GroundSource>) -> Terms {
    let mut t = Terms::default();
    t.configure(&configs(), case.seed);
    t.set_conditions(&case.conditions);
    // синтетика идёт с `air_model.enabled = off`: упрощённый профиль 0.8.0 (README фикстур)
    t.wind.set_simple_profile(true, None);
    t.statics = case.static_thermals.clone();
    t.statics_mode = case.static_mode;
    t.focuses = case.focuses.clone();
    t.set_thermal_ground(ground);
    t
}

// ---------------------------------------------------------------- сверка с эталонами W8

const SYNTH: [&str; 7] = [
    "synth_weak",
    "synth_medium",
    "synth_strong",
    "synth_storm",
    "synth_wave",
    "synth_off",
    "synth_weak",
];

/// Допуск W8 для детерминированных слагаемых: 0,05 м/с + 2 %.
fn tol(v: f32) -> f32 {
    0.05 + 0.02 * v.abs()
}

/// Точка внутри растра места (вне него высота — по краю, W5; GD считает аналитикой).
fn on_grid(place: &Place, p: [f32; 3]) -> bool {
    let g = &place.header().grid;
    let (x1, z1) = (
        g.origin_x + (f64::from(g.width) - 1.0) * g.spacing,
        g.origin_z + (f64::from(g.height) - 1.0) * g.spacing,
    );
    (g.origin_x..=x1).contains(&f64::from(p[0])) && (g.origin_z..=z1).contains(&f64::from(p[2]))
}

fn thermal_index(case: &Case) -> usize {
    case.terms
        .as_ref()
        .unwrap()
        .iter()
        .position(|n| n == "thermal")
        .unwrap()
}

/// (1) Слагаемое `thermal` (с фоновым опусканием) в точках без облаков (теги, кроме `above_base`) —
/// в допуске W8; точки с настоящим подъёмом в выборке есть (не сверка нулей).
#[test]
fn synth_thermal_term_in_w8_tolerance() {
    let mut strong = 0;
    let mut checked = 0;
    for name in &SYNTH[..6] {
        let l = load(name);
        let ti = thermal_index(&l.case);
        let mut t = terms_for(&l.case, Arc::new(SynGround));
        let fs = FieldSet::default();
        for (k, &tm) in l.case.times_s.iter().enumerate() {
            t.start_at(tm);
            let want: Vec<[f32; 4]> = l.data.slab(k, 2 + ti).collect();
            for (i, (p, tag)) in l.case.points.iter().zip(&l.case.point_tags).enumerate() {
                if tag == "above_base" || !on_grid(&l.place, *p) {
                    // облака (подсос) — RW-11; вне растра места высоту знает только аналитика GD
                    continue;
                }
                let d = terms::decompose(&t, &fs, Some(&l.place), *p, tm);
                let (g, w) = (d.vel[3][1], want[i][1]);
                assert!(
                    (g - w).abs() <= tol(w),
                    "{name} t={tm} точка {i} ({tag}) {p:?}: rust {g}, gd {w}"
                );
                checked += 1;
                if w.abs() > 1.0 {
                    strong += 1;
                }
            }
        }
    }
    assert!(checked > 600, "сверено {checked}");
    assert!(strong > 60, "точек с |w| > 1 м/с: {strong}");
}

/// (2) Набор термиков (дамп `desc.json` — всё, что держит `ThermalField.thermals`): число равно,
/// id совпадают побитно (сид `_mix`), место ≤ max(25 м, 2 % radius), w и radius ≤ 3 %, top ≤ 10 м,
/// stage ≤ 0,05 — по всем `synth_*` и моментам.
#[test]
fn synth_core_set_matches_gd_dump() {
    let mut total = 0;
    for name in &SYNTH[..6] {
        let l = load(name);
        let mut t = terms_for(&l.case, Arc::new(SynGround));
        for (k, &tm) in l.case.times_s.iter().enumerate() {
            t.start_at(tm);
            let slot = t.slots.thermal.as_slot().unwrap();
            let mut mine = Vec::new();
            slot.all_cores([1500.0, 0.0, -2500.0], 8000.0, tm, &mut mine);
            let gd = &l.frames[k].cores;
            assert_eq!(mine.len(), gd.len(), "{name} t={tm}: число ядер");
            let ids: std::collections::HashSet<i64> =
                slot.state().unwrap().all.iter().map(|a| a.id).collect();
            for g in gd {
                // ближайшее по месту
                let c = mine
                    .iter()
                    .min_by(|a, b| {
                        (a.x - g.x)
                            .hypot(a.z - g.z)
                            .total_cmp(&(b.x - g.x).hypot(b.z - g.z))
                    })
                    .unwrap();
                let d = (c.x - g.x).hypot(c.z - g.z);
                let who = format!("{name} t={tm} gd id {}", g.id);
                assert!(d <= 25.0f32.max(0.02 * g.radius), "{who}: место {d} м");
                assert!(
                    (c.w - g.w).abs() <= 0.03 * g.w.abs().max(1.0e-3) + 1e-4,
                    "{who}: w {} vs {}",
                    c.w,
                    g.w
                );
                assert!(
                    (c.radius - g.radius).abs() <= 0.03 * g.radius,
                    "{who}: radius"
                );
                assert!((c.top - g.top).abs() <= 10.0, "{who}: top");
                assert!((c.stage - g.stage).abs() <= 0.05, "{who}: stage");
                assert_eq!(c.flags, g.flags, "{who}: flags");
                assert!(
                    (c.lean_x - g.lean_x).abs() < 1e-3 && (c.lean_z - g.lean_z).abs() < 1e-3,
                    "{who}: lean"
                );
                if g.flags as u32 & 1 == 0 {
                    // id GDScript 32-битные: в f32 неточны, сверяем как f32 из i64
                    assert!(
                        ids.iter().any(|i| *i as f32 == g.id),
                        "{who}: id нет в наборе"
                    );
                }
                total += 1;
            }
        }
    }
    assert!(total > 1500, "сверено ядер {total}");
}

/// (3) `cores()` (W6, охват фокуса, `w > 0`) — подмножество дампа и содержит всё живое ближе
/// 5 км от фокуса (радиус физики 6 км, капсулы в запасе).
#[test]
fn cores_are_active_live_subset_of_dump() {
    let l = load("synth_medium");
    let mut t = terms_for(&l.case, Arc::new(SynGround));
    for (k, &tm) in l.case.times_s.iter().enumerate() {
        t.start_at(tm);
        let mut c = Vec::new();
        t.thermal_cores([1500.0, 0.0, -2500.0], 8000.0, tm, &mut c);
        let gd = &l.frames[k].cores;
        for x in &c {
            assert!(x.w > 0.0);
            assert!(
                gd.iter().any(|g| (g.x - x.x).hypot(g.z - x.z) < 1.0),
                "ядро {x:?} есть в дампе"
            );
        }
        for g in gd {
            let near = (g.x - 1500.0).hypot(g.z + 2500.0) < 5000.0;
            if near && g.w > 0.0 {
                assert!(
                    c.iter().any(|x| (g.x - x.x).hypot(g.z - x.z) < 1.0),
                    "живое ядро {g:?} в радиусе 5 км есть в cores()"
                );
            }
        }
        assert!(
            !c.is_empty() && c.len() < gd.len(),
            "{} из {}",
            c.len(),
            gd.len()
        );
    }
}

/// (4) Кромка облаков: средняя высота земли по кругу + `cloudbase_agl_m` — в 5 м от дампа.
#[test]
fn synth_cloudbase_matches_dump() {
    for name in ["synth_weak", "synth_medium", "synth_strong"] {
        let l = load(name);
        let mut t = terms_for(&l.case, Arc::new(SynGround));
        t.start_at(0.0);
        let cb = t
            .slots
            .thermal
            .as_slot()
            .unwrap()
            .setup()
            .unwrap()
            .cloudbase_msl;
        let want = f64::from(l.frames[0].cloudbase_msl);
        assert!((cb - want).abs() <= 5.0, "{name}: {cb} vs {want}");
    }
}

/// (5) Статичные термики `synth_weak`/`synth_medium` (`[-4000, 3000, 2.5, 120]`): ядро с флагом 1,
/// сила и радиус как заданы, жизни нет (NaN), стадия 1,5; в точке под осью подъём равен силе.
#[test]
fn static_thermals_weak_and_medium() {
    for name in ["synth_weak", "synth_medium"] {
        let l = load(name);
        let mut t = terms_for(&l.case, Arc::new(SynGround));
        for &tm in &l.case.times_s {
            t.start_at(tm);
            let mut c = Vec::new();
            t.thermal_cores([-4000.0, 0.0, 3000.0], 50.0, tm, &mut c);
            let s: Vec<_> = c.iter().filter(|x| x.flags as u32 & 1 == 1).collect();
            assert_eq!(s.len(), 1, "{name}");
            let s = s[0];
            assert!((s.w - 2.5).abs() < 1e-6 && (s.radius - 120.0).abs() < 1e-6);
            assert!(s.life_s.is_nan() && (s.stage - 1.5).abs() < 1e-6);
            // не дрейфует: ось у земли — в источнике
            assert!((s.x + 4000.0).abs() < 1e-3 && (s.z - 3000.0).abs() < 1e-3);
            // подъём на оси: выше разгона (150 м), ниже спада у верха
            let g = syn_height(-4000.0, 3000.0) as f32;
            let fs = FieldSet::default();
            let p = [
                -4000.0 + s.lean_x * 400.0,
                g + 400.0,
                3000.0 + s.lean_z * 400.0,
            ];
            let d = terms::decompose(&t, &fs, Some(&l.place), p, tm);
            let bg = t.weather.f64_or("background_sink_ms", 0.0) as f32;
            // маска ядра ≈ 1·ex (на оси x2 = 0), подъём — сила × (разгон 1) × Allen-вертикаль 1
            assert!(
                d.vel[3][1] > 2.4 + bg * 0.0 && d.vel[3][1] <= 2.5 + 1e-4,
                "{name}: {}",
                d.vel[3][1]
            );
        }
    }
}

// ---------------------------------------------------------------- ядро: ровная земля

struct FlatSrc<F: Fn(f64, f64) -> f64 + Send + Sync>(F);
impl<F: Fn(f64, f64) -> f64 + Send + Sync> GroundSource for FlatSrc<F> {
    fn height(&self, _x: f64, _z: f64) -> f64 {
        0.0
    }
    fn source(&self, x: f64, z: f64, _t: f64) -> f64 {
        (self.0)(x, z)
    }
}

fn sunny() -> Arc<dyn GroundSource> {
    Arc::new(FlatSrc(|_, _| 1.0))
}

fn flat_place() -> Place {
    let h = PlaceHeader::from_json(
        r#"{"version":1,"loc":{"id":"flat","center_lat":50.0,"center_lon":86.0,"utc_offset_h":6.0,
"month":7,"day":15},"grid":{"origin_x":-40000,"origin_z":-40000,"spacing":20000,"width":5,"height":5},
"surface_classes":{"grass":1},"start_sites":[]}"#,
    )
    .unwrap();
    Place::new(h, vec![0.0; 25], vec![0; 25], vec![1; 25], vec![0.5; 25]).unwrap()
}

/// Термики на ровной земле: пресет `preset` + правки погоды `over`, статичные `statics`
/// (`mode` 0 динамика, 1 только статичные).
fn flat_terms(
    preset: &str,
    over: Value,
    statics: &[[f32; 4]],
    mode: u8,
    ground: Arc<dyn GroundSource>,
) -> Terms {
    let text =
        std::fs::read_to_string(repo().join(format!("configs/weather/{preset}.json"))).unwrap();
    let mut w: Value = serde_json::from_str(&text).unwrap();
    for (k, v) in over.as_object().unwrap() {
        w[k] = v.clone();
    }
    let c = Conditions::from_json(
        &serde_json::json!({"preset": w, "start_hour": 12.0, "speed": 1.0, "blend_s": null,
            "rebuild": false})
        .to_string(),
    )
    .unwrap();
    let mut t = Terms::default();
    t.configure(&configs(), 4242);
    t.set_conditions(&c);
    t.statics = statics.to_vec();
    t.statics_mode = mode;
    t.focuses = vec![Focus {
        pos: [0.0, 0.0, 0.0],
        weight: 1.0,
    }];
    t.set_thermal_ground(ground);
    t
}

fn static_one(wind_kmh: f64, strength: f32, radius: f32) -> Terms {
    let mut t = flat_terms(
        "medium",
        serde_json::json!({"wind_speed_kmh": wind_kmh}),
        &[[0.0, 0.0, strength, radius]],
        1,
        sunny(),
    );
    t.start_at(0.01);
    t
}

/// Слагаемое `thermal` (с фоном) в точке.
fn th_at(t: &Terms, p: [f32; 3]) -> f32 {
    let d = terms::decompose(t, &FieldSet::default(), Some(&flat_place()), p, 0.01);
    d.vel[3][1]
}

fn state_all(t: &Terms) -> Vec<Arc<AtmoThermal>> {
    t.slots
        .thermal
        .as_slot()
        .unwrap()
        .state()
        .unwrap()
        .all
        .clone()
}

/// (6) Профиль (`test_thermal_profile`): ядро поднимает, подъём убывает к краю, кольцо опускания
/// сильнее фона, далеко — фон, наверху термик шире (Аллен).
#[test]
fn thermal_profile_core_ring_allen() {
    let t = static_one(0.0, 3.0, 100.0);
    let bg = t.weather.f64_or("background_sink_ms", 0.0) as f32;
    let y = 800.0;
    let w0 = th_at(&t, [0.0, y, 0.0]);
    assert!(w0 > 2.0, "ядро поднимает: {w0}");
    let mut prev = w0;
    for r in (10..90).step_by(10) {
        let w = th_at(&t, [r as f32, y, 0.0]);
        assert!(w <= prev + 1e-4, "подъём убывает: r={r} {w} > {prev}");
        prev = w;
    }
    let ring = th_at(&t, [130.0, y, 0.0]);
    assert!(ring < bg - 0.2, "кольцо {ring} < фон {bg}");
    assert!(
        (th_at(&t, [1500.0, y, 0.0]) - bg).abs() < 0.01,
        "далеко — фон"
    );
    let low = th_at(&t, [70.0, 200.0, 0.0]) / th_at(&t, [0.0, 200.0, 0.0]);
    let high = th_at(&t, [70.0, 1400.0, 0.0]) / th_at(&t, [0.0, 1400.0, 0.0]);
    assert!(high > low, "термик шире наверху: {high} > {low}");
}

/// (7) Края ядра (`test_wing_asymmetry_at_edge`): на ±5 м от 0,6 радиуса подъём различается
/// сильнее 0,15 м/с.
#[test]
fn wing_asymmetry_at_edge() {
    let t = static_one(0.0, 3.0, 100.0);
    let r = 90.0 * 0.6;
    let d = th_at(&t, [r - 5.0, 800.0, 0.0]) - th_at(&t, [r + 5.0, 800.0, 0.0]);
    assert!(d > 0.15, "разница на консолях {d}");
}

/// (8) Наклон и снос (`test_wind_drift_and_lean`): ветер с запада — ось на 1000 м смещена по
/// ветру на `lean.x · 1000`.
#[test]
fn wind_lean_shifts_axis() {
    let t = static_one(18.0, 3.0, 100.0);
    let lean = state_all(&t)[0].lean;
    assert!(lean[0] > 0.0 && lean[1].abs() < 1e-4, "{lean:?}");
    let y = 1000.0;
    let (mut best_x, mut best_w) = (-1.0e9f32, -1.0e9f32);
    for i in -50..300 {
        let x = i as f32 * 10.0;
        let w = th_at(&t, [x, y, 0.0]);
        if w > best_w {
            (best_w, best_x) = (w, x);
        }
    }
    assert!(best_x > 200.0, "ось снесена по ветру: {best_x}");
    assert!(
        (best_x - lean[0] * y).abs() <= 15.0,
        "{best_x} vs {}",
        lean[0] * y
    );
}

/// (9) Смена ветра (`test_set_wind_changes_lean_and_mean_wind`): ветер с севера — наклон на +Z.
#[test]
fn wind_change_turns_lean() {
    let mut t = static_one(10.0, 3.0, 100.0);
    assert!(state_all(&t)[0].lean[0] > 0.0);
    t.wind.set_wind(20.0 / 3.6, 0.0);
    t.start_at(0.02);
    let l = state_all(&t)[0].lean;
    assert!(l[1] > 0.0 && l[0].abs() < 1e-6, "{l:?}");
}

/// (10) Огибающая (`test_lifecycle_envelope`): нет до рождения, рост, зрелость 1, распад, нет после
/// конца; на середине распада низ оторван до половины столба, оторвавшийся термик сносится.
#[test]
fn lifecycle_envelope_cut_and_drift() {
    let mut th = AtmoThermal::blank(1);
    th.top = 1000.0;
    th.t_birth = 100.0;
    th.t_grow = 100.0;
    th.t_mature = 200.0;
    th.t_decay = 100.0;
    th.drift_vel = [5.0, 0.0];
    assert!(th.phase(50.0).env.abs() < 1e-9, "до рождения нет");
    let g = th.phase(150.0).env;
    assert!(g > 0.2 && g < 0.8, "рост {g}");
    assert!((th.phase(300.0).env - 1.0).abs() < 1e-9, "зрелость");
    let d = th.phase(450.0).env;
    assert!(d > 0.1 && d < 0.9, "распад {d}");
    assert!(th.phase(510.0).env.abs() < 1e-9, "после конца нет");
    let p = th.phase(450.0);
    assert!(
        (p.cut_h - 500.0).abs() < 1.0,
        "низ оторван до половины: {}",
        p.cut_h
    );
    assert!(
        (f64::from(p.drift[0]) - 250.0).abs() < 1.0,
        "снос {:?}",
        p.drift
    );
    assert!(th.phase(300.0).cut_h < -1.0e8, "в зрелости низ не оторван");
    // статичный — всегда 1, без отрыва и сноса
    th.is_static = true;
    let p = th.phase(450.0);
    assert!((p.env - 1.0).abs() < 1e-12 && p.drift == [0.0; 2] && p.cut_h < -1.0e8);
}

/// (11) Отрыв низа (`test_decaying_thermal_bottom_cut`): под распадающимся термиком внизу пусто,
/// наверху ещё поднимает.
#[test]
fn decaying_thermal_bottom_cut() {
    use dp_air::terms::thermal::profile::{Edge, contribution};
    let cfg = dp_air::terms::thermal::ThermalCfg::default();
    let mut th = AtmoThermal::blank(2);
    th.top = 1800.0;
    th.strength = 3.0;
    th.radius = 100.0;
    th.t_birth = -1000.0;
    th.t_grow = 100.0;
    th.t_mature = 800.0;
    th.t_decay = 400.0;
    let ph = th.phase(0.0); // середина распада
    let e = Edge { k: 0.35, w: 0.45 };
    let low = contribution(&th, &ph, &cfg, e, [0.0, 300.0, 0.0], [0.0, 0.0]);
    let high = contribution(&th, &ph, &cfg, e, [0.0, 1300.0, 0.0], [0.0, 0.0]);
    assert!(low.is_none(), "внизу пусто");
    assert!(
        high.is_some_and(|c| c.w > 0.3),
        "наверху поднимает: {high:?}"
    );
}

/// (12) Фон (`test_background_sink`): без термиков в воздухе — `background_sink_ms`; у земли нет.
#[test]
fn background_sink_fades_to_ground() {
    let mut t = flat_terms(
        "medium",
        serde_json::json!({"wind_speed_kmh": 0.0}),
        &[],
        1,
        sunny(),
    );
    t.start_at(0.01);
    let bg = t.weather.f64_or("background_sink_ms", 0.0) as f32;
    assert!(bg < 0.0);
    assert!((th_at(&t, [100.0, 600.0, 50.0]) - bg).abs() < 1e-4);
    assert!(
        th_at(&t, [100.0, 0.0, 50.0]).abs() < 1e-4,
        "у земли потока нет"
    );
    assert!(
        (th_at(&t, [100.0, 30.0, 50.0]) - 0.5 * bg).abs() < 1e-4,
        "fade на 30 м из 60"
    );
}

/// (13) Жизнь в поле (`test_lifecycle_in_field`): термиков много, есть растущие и распадающиеся,
/// через час почти все сменились.
#[test]
fn lifecycle_in_field() {
    let mut t = flat_terms("strong", serde_json::json!({}), &[], 0, sunny());
    t.start_at(0.01);
    let a0 = state_all(&t);
    assert!(a0.len() > 20, "термиков {}", a0.len());
    let grow = a0.iter().filter(|h| 0.01 < h.t_birth + h.t_grow).count();
    let dec = a0.iter().filter(|h| 0.01 > h.t_decay_start()).count();
    assert!(grow > 0 && dec > 0, "растущих {grow}, распадающихся {dec}");
    t.start_at(3600.0);
    let a1 = state_all(&t);
    let ids0: std::collections::HashSet<i64> = a0.iter().map(|h| h.id).collect();
    let common = a1.iter().filter(|h| ids0.contains(&h.id)).count();
    assert!(
        a1.len() > 20 && common < a0.len() / 4,
        "общих {common} из {}",
        a0.len()
    );
}

/// (14) Улицы (`test_cloud_streets_align_across_wind`): при сильном ветре источники стягиваются
/// к линиям улиц, разброс поперёк ветра вдвое меньше, чем без улиц.
#[test]
fn streets_align_sources() {
    let spread = |street: f64| {
        let mut t = flat_terms(
            "medium",
            serde_json::json!({"wind_speed_kmh": 35.0, "wind_from_deg": 270.0,
                "street_strength": street}),
            &[],
            0,
            sunny(),
        );
        t.start_at(0.01);
        let sp = t
            .slots
            .thermal
            .as_slot()
            .unwrap()
            .setup()
            .unwrap()
            .street_spacing;
        let all = state_all(&t);
        let s: f64 = all
            .iter()
            .map(|h| {
                let c = f64::from(h.src[2]);
                (c - (c / sp).round() * sp).abs()
            })
            .sum();
        s / all.len().max(1) as f64
    };
    let (with, without) = (spread(1.0), spread(0.0));
    assert!(with < without * 0.5, "вдоль улиц: {with} < {without}/2");
}

/// (15) Сильные дни изредка дают 7–9 м/с (`test_extreme_thermals`).
#[test]
fn extreme_thermals_exist() {
    let mut t = flat_terms(
        "strong",
        serde_json::json!({"thermal_extreme_chance": 0.2}),
        &[],
        0,
        sunny(),
    );
    t.start_at(0.01);
    let n = state_all(&t).iter().filter(|h| h.strength >= 7.0).count();
    assert!(n > 0, "термиков ≥ 7 м/с: {n}");
}

/// (16) Сила источника задаёт частоту (`test_source_strength_controls_frequency`).
#[test]
fn source_strength_controls_frequency() {
    let g = Arc::new(FlatSrc(|x, _| if x > 0.0 { 1.0 } else { 0.5 }));
    let mut t = flat_terms("strong", serde_json::json!({}), &[], 0, g);
    t.start_at(0.01);
    let all = state_all(&t);
    let hot = all.iter().filter(|h| h.src[0] > 0.0).count();
    let cold = all.len() - hot;
    assert!(hot as f64 > cold as f64 * 1.3, "{hot} > {cold}·1,3");
}

/// (17) T6: `start_at(t)` равно прогону с 0 шагами `advance`: тот же набор и те же ответы побитно.
#[test]
fn start_at_equals_run_from_zero() {
    let l = load("synth_medium");
    let mut run = terms_for(&l.case, Arc::new(SynGround));
    run.start_at(0.0);
    let mut tm = 0.0;
    while tm < 900.0 {
        tm += 0.5;
        run.advance(tm);
    }
    let mut jump = terms_for(&l.case, Arc::new(SynGround));
    jump.start_at(900.0);
    let (a, b) = (state_all(&run), state_all(&jump));
    assert_eq!(a.len(), b.len());
    let key = |h: &Arc<AtmoThermal>| h.id;
    let mut ak: Vec<_> = a.iter().map(key).collect();
    let mut bk: Vec<_> = b.iter().map(key).collect();
    ak.sort_unstable();
    bk.sort_unstable();
    assert_eq!(ak, bk);
    let fs = FieldSet::default();
    for p in l.case.points.iter().take(30) {
        let da = terms::decompose(&run, &fs, Some(&l.place), *p, 900.0);
        let db = terms::decompose(&jump, &fs, Some(&l.place), *p, 900.0);
        assert_eq!(
            da.vel[3].map(f32::to_bits),
            db.vel[3].map(f32::to_bits),
            "{p:?}"
        );
    }
}

/// (18) Ритм обновлений: набор строится раз в `refresh_interval_s`; смена погоды между секундами —
/// при следующем `advance`; без земли и места термиков нет и ничего не падает.
#[test]
fn advance_cadence_and_inputs() {
    let l = load("synth_weak");
    let mut t = terms_for(&l.case, Arc::new(SynGround));
    assert!(t.advance(0.2), "первый набор");
    assert!(!t.advance(0.9), "та же секунда — набор прежний");
    assert!(t.advance(1.1), "новая секунда");
    let n = state_all(&t).len();
    assert!(n > 5);
    // термики выключены погодой (duty 0): следующий advance пересобирает даже в той же секунде
    let mut c = l.case.conditions.clone();
    if let dp_air::Source::Preset(Value::Object(m)) = &mut c.source {
        m.insert("thermal_duty".into(), serde_json::json!(0.0));
    }
    t.set_conditions(&c);
    t.wind.set_simple_profile(true, None);
    assert!(t.advance(1.3));
    assert_eq!(state_all(&t).iter().filter(|h| !h.is_static).count(), 0);
    // слот по умолчанию — плоская земля без источников
    let mut d = Terms::default();
    d.configure(&configs(), 1);
    d.set_conditions(&l.case.conditions);
    d.start_at(10.0);
    let fs = FieldSet::default();
    let r = terms::decompose(&d, &fs, Some(&l.place), [0.0, 1500.0, 0.0], 10.0);
    assert!(
        r.vel[3][1].abs() < 1.0,
        "без источников только фон: {}",
        r.vel[3][1]
    );
}

/// (19) Облачные зацепки: по умолчанию тень 0 и подсос `th.suck`; тень облака на источнике
/// ослабляет рождённые термики (сила × (1 − тень · cloud_shade_factor)).
#[test]
fn cloud_hooks_default_zero_and_shade_weakens() {
    use dp_air::terms::thermal::{CloudHooks, ThermalSlot};
    struct Shade(f64);
    impl CloudHooks for Shade {
        fn shade_at(&self, _x: f64, _z: f64, _s: [f64; 3]) -> f64 {
            self.0
        }
    }
    let mean = |hooks: Option<f64>| {
        let mut t = flat_terms("medium", serde_json::json!({}), &[], 0, sunny());
        if let Some(sh) = hooks {
            t.slots.thermal = Arc::new(ThermalSlot::new(sunny()).with_hooks(Arc::new(Shade(sh))));
        }
        t.start_at(0.01);
        let all = state_all(&t);
        let s: f64 = all.iter().map(|h| h.strength).sum();
        (all.len(), s / all.len().max(1) as f64)
    };
    let (n0, s0) = mean(None);
    let (n1, s1) = mean(Some(0.0));
    assert_eq!(
        (n0, s0.to_bits()),
        (n1, s1.to_bits()),
        "тень 0 = без зацепки"
    );
    let (_, s2) = mean(Some(0.8));
    assert!(s2 < s0 * 0.8, "в тени слабее: {s2} < {s0}");
}

/// (20) Земля из растра места (`PlaceGround`, высота билинейно по 25 м) вместо аналитики GD:
/// число ядер то же, `thermal` в допуске W8 (в том числе `above_base` без облаков).
#[test]
fn place_ground_raster_matches_too() {
    use dp_air::terms::thermal::PlaceGround;
    for name in ["synth_weak", "synth_medium", "synth_strong", "synth_storm"] {
        let l = load(name);
        let ti = thermal_index(&l.case);
        let pl = Arc::new(fixtures::read_place(&l.case.place_path(&case_path(name))).unwrap());
        let g = Arc::new(PlaceGround::new(pl, Arc::new(|x, z, _| syn_source(x, z))));
        let mut t = terms_for(&l.case, g);
        let fs = FieldSet::default();
        for (k, &tm) in l.case.times_s.iter().enumerate() {
            t.start_at(tm);
            let mut mine = Vec::new();
            t.slots.thermal.as_slot().unwrap().all_cores(
                [1500.0, 0.0, -2500.0],
                8000.0,
                tm,
                &mut mine,
            );
            assert_eq!(mine.len(), l.frames[k].cores.len(), "{name} t={tm}");
            let want: Vec<[f32; 4]> = l.data.slab(k, 2 + ti).collect();
            for (i, p) in l.case.points.iter().enumerate() {
                if !on_grid(&l.place, *p) {
                    continue;
                }
                let d = terms::decompose(&t, &fs, Some(&l.place), *p, tm);
                assert!(
                    (d.vel[3][1] - want[i][1]).abs() <= tol(want[i][1]),
                    "{name} {i}"
                );
            }
        }
    }
}
