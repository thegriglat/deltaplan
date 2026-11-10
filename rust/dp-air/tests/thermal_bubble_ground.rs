//! TB-18: почему в игре у большинства ядер нет притока у земли (|ur| < 0,01 м/с на 10 м над рельефом).
//!
//! Тот же замер, что у `flight_probe.gd` (TB-16): для каждого ядра игры (термик набора в 2000 м от фокуса, w > 0,5 м/с)
//! радиальный приток к оси, `ur = −⟨u_h · e_ρ⟩`, по кольцам ρ = 1; 1,5; 2 радиуса ядра (`AtmoThermal::radius`), 8 азимутов,
//! на 10 м над рельефом (сумма всех термиков набора: `State::sample_bubble`). Ядра с |ur| < 0,01 разбираются по причинам
//! контрфактами на том же состоянии набора (порядок проверок = порядок причин):
//!   `terrain`   — на плоскости (высота 10 м над землёй источника) приток по тем же кольцам ≥ 0,01;
//!   `ring`      — на плоскости есть приток ≥ 0,01 при другом ρ (10…800 м), кольца 1…2 R его промахиваются;
//!   `head_high` — у земли притока нет ни при каком ρ, но выше (10…1000 м) есть: голова далеко от земли;
//!   `no_field`  — шаблона нет вообще (нет таблицы, огибающая 0): `uh = 0` на всех высотах.
//! Печатает `GRJSON {...}` на каждую местность (собирает `tools/research/thermal_bubble/round3/ground_inflow.py`) и
//! `num:zero_frac_explained=` — доля нулевых ядер, которой причина назначена и подтверждена контрфактом.
//! Запуск: `cargo test --manifest-path rust/Cargo.toml -p dp-air --release --test thermal_bubble_ground -- --nocapture`.
#![allow(clippy::needless_range_loop)]
use dp_air::terms::thermal::bubble;
use dp_air::terms::thermal::{AtmoThermal, GroundSource, NoClouds, Setup, State};
use dp_air::terms::Terms;
use dp_air::{Conditions, Configs, Focus};
use serde_json::{Value, json};
use std::collections::BTreeMap;
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
    /// Сетка высот Алтая (`~/.cache/thermal_bubble/ground_dem_altai.f32` — строит `ground_inflow.py --dem`; нет файла — случай пропускается; 401×401, шаг 30 м, строка j — z, столбец i — x).
    dem: bool,
}

const DEM_N: usize = 401;
const DEM_STEP: f64 = 30.0;

fn dem_path() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".cache/thermal_bubble/ground_dem_altai.f32")
}

fn dem() -> &'static Vec<f32> {
    static D: std::sync::OnceLock<Vec<f32>> = std::sync::OnceLock::new();
    D.get_or_init(|| {
        let b = std::fs::read(dem_path()).expect("нет сетки высот");
        b.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
    })
}

fn dem_h(x: f64, z: f64) -> f64 {
    let d = dem();
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
const ZERO_MS: f64 = 0.01;

/// Приток `−⟨u_h·e_ρ⟩` по кольцам радиусов `rhos` (м) вокруг оси `ax` на высоте `y(x,z)`.
fn ring_inflow(
    st: &State,
    setup: &Setup,
    tm: f64,
    ax: [f64; 2],
    rhos: &[f64],
    y: &dyn Fn(f64, f64) -> f64,
) -> f64 {
    let (mut sum, mut cnt) = (0.0, 0usize);
    for &rho in rhos {
        for k in 0..AZ {
            let a = std::f64::consts::TAU * k as f64 / AZ as f64;
            let (c, s) = (a.cos(), a.sin());
            let (px, pz) = (ax[0] + rho * c, ax[1] + rho * s);
            let (_, uh) = st.sample_bubble(setup, &NoClouds, [px as f32, y(px, pz) as f32, pz as f32], tm);
            sum += -(uh[0] * c + uh[1] * s);
            cnt += 1;
        }
    }
    sum / cnt as f64
}

#[derive(Default)]
struct Acc {
    n: usize,
    zero: usize,
    causes: BTreeMap<&'static str, usize>,
    by_stage: BTreeMap<&'static str, (usize, usize)>,
    ur_all: Vec<f64>,
    ur_flat_ring: Vec<f64>,
    ur_flat_best: Vec<f64>,
    rows: Vec<Value>,
}

fn stage_bin(st: f64) -> &'static str {
    if st < 0.5 {
        "рост 0–0,5"
    } else if st < 1.0 {
        "рост 0,5–1"
    } else if st < 2.0 {
        "зрелый"
    } else if st < 2.5 {
        "распад 0–0,5"
    } else {
        "распад 0,5–1"
    }
}

fn run_terrain(name: &str, ter: Terrain, times: &[f64]) -> Value {
    let mut t = scene(ter);
    t.start_at(times[0]);
    let mut acc = Acc::default();
    let g = move |x: f64, z: f64| ter.h(x, z);
    let mut tm_now = times[0];
    for (i, &tm) in times.iter().enumerate() {
        // следующее обновление набора (с таблицами)
        if i == 0 {
            tm_now = tm + 1.0;
            t.advance(tm_now);
        } else {
            tm_now = tm;
            t.advance(tm_now);
        }
        let slot = t.slots.thermal.as_slot().unwrap();
        let setup = slot.setup().unwrap().clone();
        let st = slot.state().unwrap();
        for th in &st.active {
            if th.is_static {
                continue;
            }
            let ph = th.phase(tm_now);
            let w = th.strength * ph.env;
            if w < 0.5 {
                continue;
            }
            let ax = th.axis_at(f64::from(th.src[1]), ph.drift);
            if ax[0].hypot(ax[1]) > 2000.0 {
                continue;
            }
            let r0 = th.radius;
            let y0 = f64::from(th.src[1]);
            let rhos: Vec<f64> = RING_R.iter().map(|k| k * r0).collect();
            let ur = ring_inflow(st, &setup, tm_now, ax, &rhos, &|x, z| g(x, z) + AGL);
            let ur_rings: Vec<f64> = rhos
                .iter()
                .map(|r| ring_inflow(st, &setup, tm_now, ax, &[*r], &|x, z| g(x, z) + AGL))
                .collect();
            acc.n += 1;
            acc.ur_all.push(ur);
            let sb = stage_bin(th.stage(tm_now));
            let e = acc.by_stage.entry(sb).or_insert((0, 0));
            e.0 += 1;
            let mut cause = "nonzero";
            let ur_flat_all = ring_inflow(st, &setup, tm_now, ax, &rhos, &|_, _| y0 + AGL);
            let (mut ur_flat, mut ur_best, mut rho_best) = (f64::NAN, f64::NAN, f64::NAN);
            if ur.abs() < ZERO_MS {
                acc.zero += 1;
                e.1 += 1;
                ur_flat = ring_inflow(st, &setup, tm_now, ax, &rhos, &|_, _| y0 + AGL);
                if ur_flat.abs() >= ZERO_MS {
                    cause = "terrain";
                } else {
                    // поиск по ρ на плоскости
                    let (mut best, mut rb) = (0.0f64, 0.0f64);
                    let mut rho = 10.0;
                    while rho <= 800.0 {
                        let v = ring_inflow(st, &setup, tm_now, ax, &[rho], &|_, _| y0 + AGL);
                        if v.abs() > best.abs() {
                            best = v;
                            rb = rho;
                        }
                        rho += 10.0;
                    }
                    ur_best = best;
                    rho_best = rb;
                    if best.abs() >= ZERO_MS {
                        cause = "ring";
                    } else {
                        // выше земли?
                        let mut aloft = 0.0f64;
                        for hk in 1..=20 {
                            let h = f64::from(hk) * 50.0;
                            for &rho in &[0.5 * r0, r0, 1.5 * r0, 2.0 * r0, 3.0 * r0] {
                                let v = ring_inflow(st, &setup, tm_now, ax, &[rho], &|_, _| y0 + h);
                                aloft = aloft.max(v.abs());
                            }
                        }
                        cause = if aloft >= ZERO_MS { "head_high" } else { "no_field" };
                    }
                }
                *acc.causes.entry(cause).or_insert(0) += 1;
            }
            if !ur_flat.is_nan() {
                acc.ur_flat_ring.push(ur_flat);
            }
            if !ur_best.is_nan() {
                acc.ur_flat_best.push(ur_best);
            }
            // диагностика головы
            let (zc, rh) = bubble::source_of(th)
                .and_then(|(s, zi)| bubble::state(&s, zi, tm_now).map(|b| (b.zc, b.r)))
                .unwrap_or((f64::NAN, f64::NAN));
            if acc.rows.len() < 60000 {
                acc.rows.push(json!({
                    "id": th.id, "tm": tm_now, "stage": th.stage(tm_now), "env": ph.env, "w": w,
                    "zl": th.top - y0, "r_core": r0, "ur": ur, "ur_flat": if ur_flat.is_nan() { Value::Null } else { json!(ur_flat) },
                    "ur_best_flat": if ur_best.is_nan() { Value::Null } else { json!(ur_best) },
                    "rho_best": if rho_best.is_nan() { Value::Null } else { json!(rho_best) },
                    "head_zc": if zc.is_nan() { Value::Null } else { json!(zc) },
                    "head_r": if rh.is_nan() { Value::Null } else { json!(rh) },
                    "cause": cause, "ur_flat_all": ur_flat_all, "ur_r1": ur_rings[0], "ur_r15": ur_rings[1], "ur_r2": ur_rings[2],
                }));
            }
        }
    }

    // по ядрам (как в игре: среднее знаковое по замерам ядра) и по стадиям
    let mut cores: BTreeMap<i64, Vec<&Value>> = BTreeMap::new();
    for r in &acc.rows {
        cores.entry(r["id"].as_i64().unwrap()).or_default().push(r);
    }
    let mut core_rows = Vec::new();
    let (mut c_n, mut c_zero, mut c_cancel) = (0usize, 0usize, 0usize);
    let mut c_causes: BTreeMap<String, usize> = BTreeMap::new();
    for (id, v) in &cores {
        if v.len() < 3 {
            continue;
        }
        let n = v.len() as f64;
        let mean = v.iter().map(|r| r["ur"].as_f64().unwrap()).sum::<f64>() / n;
        let mabs = v.iter().map(|r| r["ur"].as_f64().unwrap().abs()).sum::<f64>() / n;
        let n_in = v.iter().filter(|r| r["ur"].as_f64().unwrap() >= ZERO_MS).count();
        let n_out = v.iter().filter(|r| r["ur"].as_f64().unwrap() <= -ZERO_MS).count();
        let mut cc: BTreeMap<String, usize> = BTreeMap::new();
        for r in v {
            *cc.entry(r["cause"].as_str().unwrap().to_string()).or_default() += 1;
        }
        c_n += 1;
        let zero = mean.abs() < ZERO_MS;
        let mean_flat = v.iter().map(|r| r["ur_flat_all"].as_f64().unwrap()).sum::<f64>() / n;
        let mut cause = String::from("nonzero");
        if zero {
            c_zero += 1;
            if mean_flat.abs() >= ZERO_MS {
                // на плоскости (высота 10 м над землёй источника) приток есть: гасит рельеф (high = y − y_src)
                cause = "terrain".into();
            } else if mabs >= ZERO_MS {
                cause = "cancel".into();
                c_cancel += 1;
            } else {
                cause = cc
                    .iter()
                    .filter(|(k, _)| k.as_str() != "nonzero")
                    .max_by_key(|(_, c)| **c)
                    .map(|(k, _)| k.clone())
                    .unwrap_or_else(|| "none".into());
            }
            *c_causes.entry(cause.clone()).or_default() += 1;
        }
        core_rows.push(json!({"id": id, "n_obs": v.len(), "ur_mean": mean, "ur_mean_flat": mean_flat, "ur_mabs": mabs, "n_in": n_in, "n_out": n_out,
            "cause": cause, "stage_mean": v.iter().map(|r| r["stage"].as_f64().unwrap()).sum::<f64>() / n,
            "r_core": v[0]["r_core"], "zl": v[0]["zl"], "w_mean": v.iter().map(|r| r["w"].as_f64().unwrap()).sum::<f64>() / n}));
    }
    // по стадиям: средние ur по кольцам (знаковые), доля притока/оттока
    let mut st_rows = serde_json::Map::new();
    for sb in ["рост 0–0,5", "рост 0,5–1", "зрелый", "распад 0–0,5", "распад 0,5–1"] {
        let sel: Vec<&Value> = acc.rows.iter().filter(|r| stage_bin(r["stage"].as_f64().unwrap()) == sb).collect();
        if sel.is_empty() {
            continue;
        }
        let m = |k: &str| sel.iter().map(|r| r[k].as_f64().unwrap()).sum::<f64>() / sel.len() as f64;
        let fr = |f: &dyn Fn(f64) -> bool| sel.iter().filter(|r| f(r["ur"].as_f64().unwrap())).count() as f64 / sel.len() as f64;
        st_rows.insert(sb.into(), json!({"n": sel.len(), "ur_mean": m("ur"), "ur_r1": m("ur_r1"), "ur_r15": m("ur_r15"),
            "ur_r2": m("ur_r2"), "frac_in": fr(&|u| u >= ZERO_MS), "frac_out": fr(&|u| u <= -ZERO_MS), "frac_zero": fr(&|u| u.abs() < ZERO_MS)}));
    }
    let mut stage = serde_json::Map::new();
    for (k, (n, z)) in &acc.by_stage {
        stage.insert((*k).to_string(), json!({"n": n, "zero": z}));
    }
    let causes: serde_json::Map<String, Value> = acc.causes.iter().map(|(k, v)| ((*k).to_string(), json!(v))).collect();
    let med = |v: &Vec<f64>| -> f64 {
        let mut a: Vec<f64> = v.iter().map(|x| x.abs()).collect();
        a.sort_by(|x, y| x.total_cmp(y));
        if a.is_empty() { f64::NAN } else { a[a.len() / 2] }
    };
    let out = json!({
        "terrain": name, "slope": ter.slope, "amp": ter.amp, "lam": ter.lam,
        "n": acc.n, "zero": acc.zero, "zero_frac": acc.zero as f64 / acc.n.max(1) as f64,
        "causes": causes, "by_stage": stage,
        "median_abs_ur": med(&acc.ur_all),
        "cores": {"n": c_n, "zero": c_zero, "zero_frac": c_zero as f64 / c_n.max(1) as f64, "cancel": c_cancel, "causes": c_causes},
        "by_stage_signed": st_rows, "core_rows": core_rows,
    });
    println!(
        "ground[{name}]: ядер-замеров {} нулевых {} ({:.0}%) причины {:?}",
        acc.n,
        acc.zero,
        100.0 * acc.zero as f64 / acc.n.max(1) as f64,
        acc.causes
    );
    println!("GRJSON {out}");
    out
}

#[test]
fn ground_inflow() {
    let times: Vec<f64> = (0..41).map(|k| 1200.0 + 30.0 * f64::from(k)).collect();
    let mut cases = vec![
        ("flat", Terrain { slope: 0.0, amp: 0.0, lam: 500.0, dem: false }),
        ("slope10", Terrain { slope: 0.18, amp: 0.0, lam: 500.0, dem: false }),
        ("slope20", Terrain { slope: 0.36, amp: 0.0, lam: 500.0, dem: false }),
        ("slope30", Terrain { slope: 0.58, amp: 0.0, lam: 500.0, dem: false }),
        ("slope40", Terrain { slope: 0.84, amp: 0.0, lam: 500.0, dem: false }),
        ("hills60", Terrain { slope: 0.0, amp: 60.0, lam: 500.0, dem: false }),
        ("hills150", Terrain { slope: 0.0, amp: 150.0, lam: 700.0, dem: false }),
        ("mountain", Terrain { slope: 0.36, amp: 150.0, lam: 600.0, dem: false }),
    ];
    if dem_path().exists() {
        cases.push(("altai", Terrain { slope: 0.0, amp: 0.0, lam: 500.0, dem: true }));
    } else {
        println!("ground: нет {} — случай altai пропущен", dem_path().display());
    }
    let (mut n_tot, mut zero_tot, mut expl_tot) = (0usize, 0usize, 0usize);
    let mut sets = Vec::new();
    for (name, ter) in cases {
        let v = run_terrain(name, ter, &times);
        let c = &v["cores"];
        n_tot += c["n"].as_u64().unwrap() as usize;
        zero_tot += c["zero"].as_u64().unwrap() as usize;
        for (k, x) in c["causes"].as_object().unwrap() {
            if k != "none" && k != "no_field" {
                expl_tot += x.as_u64().unwrap() as usize;
            }
        }
        sets.push(v);
    }
    // «no_field» тоже объяснение (причина названа, контрфакт: шаблона нет), но отдельно не засчитывается как «физика»
    let frac_expl = if zero_tot == 0 { 1.0 } else { expl_tot as f64 / zero_tot as f64 };
    let _ = sets;
    println!("n_total={n_tot} zero_total={zero_tot}");
    println!("num:zero_frac_explained={frac_expl:.3}");
    assert!(n_tot > 50, "мало ядер: {n_tot}");
}
