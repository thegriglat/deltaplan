//! TB-20 (TB4 v5): приток у земли в рельефе — высота таблицы пузыря над локальной землёй (`sample_bubble_agl`).
//! `bubble_terrain_inflow` — кольца 1; 1,5; 2 R ядра на 10 м над рельефом (склон 20° и холм), как в TB-16/TB-18:
//! `terrain_zero_frac=` — доля ядер с |ur| < 0,01 м/с, `terrain_median_ur=` — медиана ur по ядрам.
//! `bubble_agl_blend_smooth` — вертикали через склон, шаг 1 м, agl 0…200 м: `agl_blend_max_dv_per_m=` — max|Δv|/1 м.
#![allow(clippy::needless_range_loop)]
use dp_air::terms::thermal::{GroundSource, NoClouds, Setup, State};
use dp_air::terms::Terms;
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

/// Рельеф: плоскость, уклон (градиент `slope` вдоль x), холмы (две синусоиды амплитуды `amp`, длины волны `lam`).
#[derive(Clone, Copy)]
struct Terrain {
    slope: f64,
    amp: f64,
    lam: f64,
    /// Сетка высот Алтая (`~/.cache/thermal_bubble/ground_dem_altai.f32`, 401×401, шаг 30 м); нет файла — случай пропускается.
    dem: bool,
}

const DEM_N: usize = 401;
const DEM_STEP: f64 = 30.0;

fn dem_path() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".cache/thermal_bubble/ground_dem_altai.f32")
}

fn dem_h(x: f64, z: f64) -> f64 {
    static D: std::sync::OnceLock<Vec<f32>> = std::sync::OnceLock::new();
    let d = D.get_or_init(|| {
        let b = std::fs::read(dem_path()).expect("нет сетки высот");
        b.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
    });
    let fi = (x / DEM_STEP + 200.0).clamp(0.0, (DEM_N - 1) as f64 - 1e-9);
    let fj = (z / DEM_STEP + 200.0).clamp(0.0, (DEM_N - 1) as f64 - 1e-9);
    let (i, j) = (fi as usize, fj as usize);
    let (tx, tz) = (fi - i as f64, fj - j as f64);
    let at = |a: usize, b: usize| f64::from(d[b * DEM_N + a]);
    at(i, j) * (1.0 - tx) * (1.0 - tz) + at(i + 1, j) * tx * (1.0 - tz) + at(i, j + 1) * (1.0 - tx) * tz + at(i + 1, j + 1) * tx * tz
}

impl Terrain {
    fn h(&self, x: f64, z: f64) -> f64 {
        if self.dem {
            return dem_h(x, z);
        }
        let k = std::f64::consts::TAU / self.lam;
        self.slope * x + self.amp * ((k * x).sin() * (0.7 * k * z + 1.0).cos() + 0.5 * (1.9 * k * z).sin())
    }
}
struct Ground(Terrain);
impl GroundSource for Ground {
    fn height(&self, x: f64, z: f64) -> f64 {
        self.0.h(x, z)
    }
    fn source(&self, x: f64, z: f64, _t: f64) -> f64 {
        if x.abs() < 5500.0 && z.abs() < 5500.0 { 1.0 } else { 0.0 }
    }
}

fn scene(ter: Terrain) -> Terms {
    let text = std::fs::read_to_string(repo().join("configs/weather/strong.json")).unwrap();
    let mut w: Value = serde_json::from_str(&text).unwrap();
    w["wind_speed_kmh"] = json!(18.0);
    w["wind_from_deg"] = json!(270.0);
    let c = Conditions::from_json(
        &json!({"preset": w, "start_hour": 12.0, "speed": 1.0, "blend_s": null, "rebuild": false}).to_string(),
    )
    .unwrap();
    let cfg = configs_with(|v| {
        v["thermal"]["generation_radius_m"] = json!(8000.0);
    });
    let mut t = Terms::default();
    t.configure(&cfg, 4242);
    t.thermal_async = false;
    t.set_conditions(&c);
    t.focuses = vec![Focus { pos: [0.0, 0.0, 0.0], weight: 1.0 }];
    t.set_thermal_ground(Arc::new(Ground(ter)));
    t
}


const RING_R: [f64; 3] = [1.0, 1.5, 2.0];
const AZ: usize = 8;
const AGL: f64 = 10.0;
/// Вертикали блендинга — где рельеф отличается от плоскости источника каждого близкого термика не больше чем на `OFF_MAX` м (сдвиг сшивки h_src − agl = эта разность: при ±1000 м сшивка 60–120 м протаскивает опрос через всю таблицу, градиент определяется таблицей, а не сшивкой).
const OFF_MAX: f64 = 70.0;
/// Радиус, в котором чужие пузыри считаются достающими до вертикали, м.
const REACH_M: f64 = 1500.0;
const ZERO_MS: f64 = 0.01;
const SLOPE20: Terrain = Terrain { slope: 0.36, amp: 0.0, lam: 500.0, dem: false };
const HILLS: Terrain = Terrain { slope: 0.0, amp: 60.0, lam: 500.0, dem: false };

/// Набор термиков сцены на моменты `times`: для каждого подходящего ядра вызывает `f(state, setup, t, ось, термик)`.
fn each_core(ter: Terrain, times: &[f64], mut f: impl FnMut(&State, &Setup, f64, [f64; 2], &dp_air::terms::thermal::AtmoThermal)) {
    let mut t = scene(ter);
    t.start_at(times[0]);
    for (i, &tm) in times.iter().enumerate() {
        let now = if i == 0 { tm + 1.0 } else { tm };
        t.advance(now);
        let slot = t.slots.thermal.as_slot().unwrap();
        let setup = slot.setup().unwrap().clone();
        let st = slot.state().unwrap();
        for th in &st.active {
            if th.is_static {
                continue;
            }
            let ph = th.phase(now);
            if th.strength * ph.env < 0.5 {
                continue;
            }
            let ax = th.axis_at(f64::from(th.src[1]), ph.drift);
            if ax[0].hypot(ax[1]) > 2000.0 {
                continue;
            }
            f(st, &setup, now, ax, th);
        }
    }
}

fn times() -> Vec<f64> {
    (0..21).map(|k| 1200.0 + 60.0 * f64::from(k)).collect()
}

/// Средний радиальный приток `−⟨u_h·e_ρ⟩` по кольцам на `AGL` м над рельефом (опрос с `agl`).
fn ring_ur(st: &State, setup: &Setup, tm: f64, ax: [f64; 2], r0: f64, ter: Terrain) -> f64 {
    let (mut sum, mut cnt) = (0.0, 0usize);
    for k in RING_R {
        for j in 0..AZ {
            let a = std::f64::consts::TAU * j as f64 / AZ as f64;
            let (c, s) = (a.cos(), a.sin());
            let (px, pz) = (ax[0] + k * r0 * c, ax[1] + k * r0 * s);
            let y = ter.h(px, pz) + AGL;
            let (_, uh) = st.sample_bubble_agl(setup, &NoClouds, [px as f32, y as f32, pz as f32], tm, AGL);
            sum += -(uh[0] * c + uh[1] * s);
            cnt += 1;
        }
    }
    sum / cnt as f64
}

#[test]
fn bubble_terrain_inflow() {
    let ts = times();
    let (mut n, mut zero) = (0usize, 0usize);
    let mut urs = Vec::new();
    for (name, ter) in [("slope20", SLOPE20), ("hills", HILLS)] {
        let (mut nn, mut zz) = (0usize, 0usize);
        each_core(ter, &ts, |st, setup, tm, ax, th| {
            let ur = ring_ur(st, setup, tm, ax, th.radius, ter);
            nn += 1;
            if ur.abs() < ZERO_MS {
                zz += 1;
            }
            urs.push(ur);
        });
        println!("{name}: n={nn} zero={zz}");
        n += nn;
        zero += zz;
    }
    assert!(n > 20, "мало ядер: {n}");
    urs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let med = urs[urs.len() / 2];
    println!("num:terrain_zero_frac={:.4}", zero as f64 / n as f64);
    println!("num:terrain_median_ur={med:.4}");
}

#[test]
fn bubble_agl_blend_smooth() {
    let ts = [1500.0, 1800.0, 2100.0];
    let mut max_dv = 0.0f64;
    let mut nvert = 0usize;
    for ter in [SLOPE20, HILLS] {
        each_core(ter, &ts, |st, setup, tm, ax, th| {
            let r0 = th.radius;
            for &k in &[0.0, 0.5, 1.0, 2.0] {
                let (px, pz) = (ax[0] + k * r0, ax[1]);
                let g = ter.h(px, pz);
                // все термики, чьи пузыри могут достать до вертикали, должны стоять на плоскости не дальше OFF_MAX от неё
                let off_max = st
                    .active
                    .iter()
                    .filter(|o| !o.is_static)
                    .filter(|o| {
                        let a = o.axis_at(f64::from(o.src[1]), o.phase(tm).drift);
                        (a[0] - px).hypot(a[1] - pz) < REACH_M
                    })
                    .map(|o| (g - f64::from(o.src[1])).abs())
                    .fold(0.0f64, f64::max);
                if off_max > OFF_MAX {
                    continue;
                }
                let mut prev: Option<[f64; 3]> = None;
                for m in 0..=200 {
                    let agl = f64::from(m);
                    let y = g + agl;
                    if y >= th.top {
                        break;
                    }
                    let (o, uh) = st.sample_bubble_agl(setup, &NoClouds, [px as f32, y as f32, pz as f32], tm, agl);
                    let v = [o[0], uh[0], uh[1]];
                    if let Some(p) = prev {
                        let d = ((v[0] - p[0]).powi(2) + (v[1] - p[1]).powi(2) + (v[2] - p[2]).powi(2)).sqrt();
                        if d > max_dv {
                            max_dv = d;
                        }
                    }
                    prev = Some(v);
                }
                nvert += 1;
            }
        });
    }
    assert!(nvert >= 8, "мало вертикалей: {nvert}");
    println!("verticals={nvert}");
    println!("num:agl_blend_max_dv_per_m={max_dv:.4}");
}

/// Для отчёта: до/после (`sample_bubble` на плоскости источника против `sample_bubble_agl`) на склоне, холме и Алтае,
/// плюс поле выше 120 м над рельефом — совпадение побитно (`high_field_max_diff=`).
#[test]
fn bubble_terrain_before_after() {
    let ts = times();
    let mut cases = vec![("slope20", SLOPE20), ("hills", HILLS)];
    if dem_path().exists() {
        cases.push(("altai", Terrain { slope: 0.0, amp: 0.0, lam: 500.0, dem: true }));
    }
    let mut hi_diff = 0.0f64;
    for (name, ter) in cases {
        let (mut n, mut z0, mut z1) = (0usize, 0usize, 0usize);
        let (mut u0, mut u1) = (Vec::new(), Vec::new());
        each_core(ter, &ts, |st, setup, tm, ax, th| {
            let r0 = th.radius;
            let (mut s0, mut s1, mut cnt) = (0.0, 0.0, 0usize);
            for k in RING_R {
                for j in 0..AZ {
                    let a = std::f64::consts::TAU * j as f64 / AZ as f64;
                    let (c, s) = (a.cos(), a.sin());
                    let (px, pz) = (ax[0] + k * r0 * c, ax[1] + k * r0 * s);
                    let p = [px as f32, (ter.h(px, pz) + AGL) as f32, pz as f32];
                    let (_, a0) = st.sample_bubble(setup, &NoClouds, p, tm);
                    let (_, a1) = st.sample_bubble_agl(setup, &NoClouds, p, tm, AGL);
                    s0 += -(a0[0] * c + a0[1] * s);
                    s1 += -(a1[0] * c + a1[1] * s);
                    cnt += 1;
                    // выше 120 м над рельефом: agl = высота над землёй, h_src не меняется — поле то же
                    let hp = [px as f32, (ter.h(px, pz) + 150.0) as f32, pz as f32];
                    let (w0, b0) = st.sample_bubble(setup, &NoClouds, hp, tm);
                    let (w1, b1) = st.sample_bubble_agl(setup, &NoClouds, hp, tm, 150.0);
                    hi_diff = hi_diff.max((w0[0] - w1[0]).abs()).max((b0[0] - b1[0]).abs()).max((b0[1] - b1[1]).abs());
                }
            }
            let (m0, m1) = (s0 / cnt as f64, s1 / cnt as f64);
            n += 1;
            z0 += usize::from(m0.abs() < ZERO_MS);
            z1 += usize::from(m1.abs() < ZERO_MS);
            u0.push(m0);
            u1.push(m1);
        });
        let med = |v: &mut Vec<f64>| {
            v.sort_by(|a, b| a.partial_cmp(b).unwrap());
            v[v.len() / 2]
        };
        println!(
            "BA {name}: n={n} zero_before={:.4} zero_after={:.4} median_ur_before={:.4} median_ur_after={:.4}",
            z0 as f64 / n as f64,
            z1 as f64 / n as f64,
            med(&mut u0),
            med(&mut u1)
        );
    }
    println!("high_field_max_diff={hi_diff:e}");
}
