//! Цена и неизменность опроса шаблона пузыря (TB-19, круг 3 п. 8): `State::sample_bubble` на сцене бюджета (плотность
//! Аллена) — `sample_same_as_before` сверяет поле с записью до правок (`data/thermal_bubble_sample_v5.json`),
//! `bubble_sample_cost` меряет ns на точку (release, один поток). Запись фикстуры: `TB_WRITE_FIXTURE=1`.
use dp_air::terms::Terms;
use dp_air::terms::thermal::bubble::BubbleCache;
use dp_air::terms::thermal::{AtmoThermal, GroundSource, NoClouds, State};
use dp_air::{Conditions, Configs, Focus};
use serde_json::{Value, json};
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
            out.push((
                name.trim_end_matches(".json").to_string(),
                std::fs::read_to_string(&p).unwrap(),
            ));
        }
    }
}

/// Конфиги игры; `patch` правит `atmosphere.json`.
fn configs_with(patch: impl Fn(&mut Value)) -> Arc<Configs> {
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
    Arc::new(Configs::new(files))
}

/// Источники только в круге радиуса 800 м вокруг начала: термиков мало и они разнесены (проверка знаков).
struct Spot;
impl GroundSource for Spot {
    fn height(&self, _x: f64, _z: f64) -> f64 {
        0.0
    }
    fn source(&self, x: f64, z: f64, _t: f64) -> f64 {
        if x.hypot(z) < 800.0 { 1.0 } else { 0.0 }
    }
}

fn scene_with(patch: impl Fn(&mut Value), ground: Arc<dyn GroundSource>) -> Terms {
    let text = std::fs::read_to_string(repo().join("configs/weather/strong.json")).unwrap();
    let mut w: Value = serde_json::from_str(&text).unwrap();
    w["wind_speed_kmh"] = json!(18.0);
    w["wind_from_deg"] = json!(270.0);
    let c = Conditions::from_json(
        &json!({"preset": w, "start_hour": 12.0, "speed": 1.0, "blend_s": null, "rebuild": false})
            .to_string(),
    )
    .unwrap();
    let cfg = configs_with(|v| {
        v["thermal"]["generation_radius_m"] = json!(8000.0);
        patch(v);
    });
    let mut t = Terms::default();
    t.configure(&cfg, 4242);
    t.thermal_async = false;
    t.set_conditions(&c);
    t.focuses = vec![Focus {
        pos: [0.0, 0.0, 0.0],
        weight: 1.0,
    }];
    t.set_thermal_ground(ground);
    t
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z >> 11) as f64 / (1u64 << 53) as f64
    }
}

fn setup_on() -> Arc<dp_air::terms::thermal::Setup> {
    let mut on = scene_with(|_| {}, Arc::new(Spot));
    on.start_at(1200.0);
    on.slots.thermal.as_slot().unwrap().setup().unwrap().clone()
}

/// Динамический термик игры для проверок: источник `(x, z)`, столб `zl`, сила `w0`, рождён в `t_birth`.
fn thermal_at(id: i64, x: f32, z: f32, zl: f64, w0: f64, t_birth: f64) -> AtmoThermal {
    let mut h = AtmoThermal::blank(id);
    h.src = [x, 0.0, z];
    h.top = zl;
    h.strength = w0;
    h.radius = 100.0;
    h.drift_vel = [4.0, 0.0];
    h.drift_delay = 60.0;
    h.t_birth = t_birth;
    h.t_grow = 180.0;
    h.t_mature = 510.0;
    h.t_decay = 300.0;
    h
}

/// Сцена плотности Аллена n_A = 8,5/z_l² (z_l 1400 м): термики со случайными стадиями жизни и силой 1,5…4 м/с в области
/// вокруг одного (1) или четырёх разнесённых фокусов; `t0` — момент сцены.
fn allen_scene(n_foc: usize, t0: f64) -> Vec<Arc<AtmoThermal>> {
    let zl = 1400.0;
    let n_a = 8.5 / (zl * zl);
    let (x_lo, x_hi, z_half) = if n_foc == 1 {
        (-3600.0, 5400.0, 3600.0)
    } else {
        (-6600.0, 8400.0, 6100.0) // область вокруг четырёх разнесённых фокусов
    };
    let mut rng = Rng(2026);
    let n = (n_a * (x_hi - x_lo) * 2.0 * z_half) as usize;
    (0..n)
        .map(|i| {
            let x = x_lo + rng.next() * (x_hi - x_lo);
            let z = (rng.next() * 2.0 - 1.0) * z_half;
            let w0 = 1.5 + 2.5 * rng.next();
            let life = 180.0 + 510.0 + 300.0;
            let mut h = thermal_at(
                i as i64 + 1,
                x as f32,
                z as f32,
                zl,
                w0,
                t0 - rng.next() * life,
            );
            h.t_grow = 120.0 + 120.0 * rng.next();
            h.t_mature = 300.0 + 420.0 * rng.next();
            h.t_decay = 150.0 + 150.0 * rng.next();
            Arc::new(h)
        })
        .collect()
}

const T0: f64 = 1000.0;

fn scene_state() -> (Arc<dp_air::terms::thermal::Setup>, State) {
    let setup = setup_on();
    let all = allen_scene(1, T0);
    let cache = BubbleCache::default();
    let st = State::build_cached(&setup, all, T0, &[[0.0, 0.0]], 1.0, 0, &cache, true);
    assert!(st.bubble_count() > 10);
    (setup, st)
}

/// Точки круга 1500 м вокруг фокуса, высота 10…1400 м (как `sample_cost`).
fn random_points(n: usize, seed: u64) -> Vec<[f32; 3]> {
    let mut rng = Rng(seed);
    (0..n)
        .map(|_| {
            let r = 1500.0 * rng.next().sqrt();
            let a = std::f64::consts::TAU * rng.next();
            [
                (r * a.cos()) as f32,
                (10.0 + 1390.0 * rng.next()) as f32,
                (r * a.sin()) as f32,
            ]
        })
        .collect()
}

/// Точки у термиков с таблицей: цилиндр 3 радиуса вокруг оси, от земли источника до верха.
fn near_thermal_points(st: &State, n: usize, seed: u64, t: f64) -> Vec<[f32; 3]> {
    let mut rng = Rng(seed);
    let hs: Vec<_> = st.active.iter().filter(|h| !h.is_static).collect();
    (0..n)
        .map(|_| {
            let h = hs[(rng.next() * hs.len() as f64) as usize % hs.len()];
            let ph = h.phase(t);
            let y0 = f64::from(h.src[1]);
            let y = y0 + 5.0 + rng.next() * (h.top - y0 + 100.0);
            let ax = h.axis_at(y, ph.drift);
            let r = 3.0 * h.radius * rng.next().sqrt();
            let a = std::f64::consts::TAU * rng.next();
            [
                (ax[0] + r * a.cos()) as f32,
                y as f32,
                (ax[1] + r * a.sin()) as f32,
            ]
        })
        .collect()
}

const MOMENTS: [f64; 3] = [T0, T0 + 0.4, T0 + 0.9];

#[derive(serde::Serialize, serde::Deserialize)]
struct Rec {
    t: f64,
    pts: Vec<[f32; 3]>,
    /// `[w, mask, sigma, uh_x, uh_z]` по точкам.
    out: Vec<[f64; 5]>,
}

fn eval(
    st: &State,
    setup: &dp_air::terms::thermal::Setup,
    t: f64,
    pts: &[[f32; 3]],
) -> Vec<[f64; 5]> {
    pts.iter()
        .map(|&p| {
            let (o, uh) = st.sample_bubble(setup, &NoClouds, p, t);
            [o[0], o[1], o[2], uh[0], uh[1]]
        })
        .collect()
}

fn fixture_path() -> PathBuf {
    repo().join("rust/dp-air/tests/data/thermal_bubble_sample_v5.json")
}

/// Поле опроса не изменилось: 3 момента × 3000 точек (1000 случайных в круге 1500 м + 2000 у термиков), `w`, маска, `σ`,
/// `uh` против записи до правок; `max_rel_diff` = max|Δ| / max|v| по всем значениям (отдельно по компонентам:
/// `w`+`uh` — в м/с, маска и σ — своя шкала). Печатает `max_rel_diff=`.
#[test]
fn sample_same_as_before() {
    let (setup, st) = scene_state();
    if std::env::var("TB_WRITE_FIXTURE").is_ok() {
        let recs: Vec<Rec> = MOMENTS
            .iter()
            .enumerate()
            .map(|(k, &t)| {
                let mut pts = random_points(1000, 77 + k as u64);
                pts.extend(near_thermal_points(&st, 2000, 91 + k as u64, t));
                let out = eval(&st, &setup, t, &pts);
                Rec { t, pts, out }
            })
            .collect();
        std::fs::write(fixture_path(), serde_json::to_string(&recs).unwrap()).unwrap();
        println!("fixture written");
        return;
    }
    let recs: Vec<Rec> =
        serde_json::from_str(&std::fs::read_to_string(fixture_path()).unwrap()).unwrap();
    assert_eq!(recs.len(), 3);
    let (mut worst, mut nonzero) = (0.0f64, 0usize);
    for r in &recs {
        let now = eval(&st, &setup, r.t, &r.pts);
        for c in 0..5 {
            let vmax = r.out.iter().map(|o| o[c].abs()).fold(0.0, f64::max);
            let dmax = now
                .iter()
                .zip(&r.out)
                .map(|(a, b)| (a[c] - b[c]).abs())
                .fold(0.0, f64::max);
            if vmax > 0.0 {
                worst = worst.max(dmax / vmax);
            } else {
                assert_eq!(dmax, 0.0);
            }
        }
        nonzero += r.out.iter().filter(|o| o[0] != 0.0).count();
    }
    println!("nonzero_w={nonzero}");
    println!("max_rel_diff={worst:e}");
    assert!(nonzero > 2000, "в записи мало ненулевых точек");
    assert!(worst <= 1e-6, "поле изменилось: {worst:e}");
}

/// Цена опроса, ns на точку (release, один поток): 20000 случайных точек круга 1500 м, лучший из 21 прогона (машина
/// общая: помехи только прибавляют время, минимум — оценка без них). `sample_ns_bubble=` — `State::sample_bubble`, `sample_ns_profile=` — `State::sample` (профиль, та же сцена).
#[test]
#[cfg_attr(debug_assertions, ignore = "цена меряется в release")]
fn bubble_sample_cost() {
    let (setup, st) = scene_state();
    let pts = random_points(20000, 77);
    let time = |bubble: bool| -> f64 {
        let (mut best, mut acc) = (f64::INFINITY, 0.0);
        for _ in 0..21 {
            let ts = std::time::Instant::now();
            for p in &pts {
                acc += if bubble {
                    st.sample_bubble(&setup, &NoClouds, *p, T0).0[0]
                } else {
                    st.sample(&setup, &NoClouds, *p, T0)[0]
                };
            }
            best = best.min(ts.elapsed().as_secs_f64() * 1e9 / pts.len() as f64);
        }
        std::hint::black_box(acc);
        best
    };
    let prof = time(false);
    let bub = time(true);
    println!("sample_ns_profile={prof:.0}");
    println!("sample_ns_bubble={bub:.0}");
}
