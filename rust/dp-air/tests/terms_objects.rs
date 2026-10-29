//! RW-11f: объекты-облака W6 v4 (`terms::objects::cloud_objects`, 22 поля) против дампа GD
//! (`tests/data/RW-11f/cloud_objects.json`, опорная ревизия c591b1026: `ThermalField`/
//! `CloudModel`/`StormField` на `synth_storm` и `synth_medium`, моменты 0/900/3600 и прошлые
//! t - 10, t - 60), уникальность `id`, `radius < 0`, `Core.storm` Cb = `storm_k`.
use dp_air::Configs;
use dp_air::Core;
use dp_air::fixtures::{self, Case};
use dp_air::terms::objects::{OBJ_STRIDE, ObjRecord, cloud_objects};
use dp_air::terms::thermal::GroundSource;
use dp_air::terms::{self, Terms};
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

/// Конфиги игры как у `synth_*` (`config_overrides`: круг генерации 8 км).
fn configs() -> Arc<Configs> {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere.json" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["thermal"]["generation_radius_m"] = serde_json::json!(8000.0);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Arc::new(Configs::new(files))
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

fn syn_source(x: f64, z: f64) -> f64 {
    let k = 0.65 + 0.35 * (x / 830.0 + 1.3).sin() * (z / 1170.0 - 0.4).cos();
    let n = syn_normal(x, z);
    let s = {
        let (a, b, c) = (0.3f32, 0.8f32, 0.5f32);
        let l = (a * a + b * b + c * c).sqrt();
        [a / l, b / l, c / l]
    };
    let d = f64::from(n[0] * s[0] + n[1] * s[1] + n[2] * s[2]);
    (k * (0.35 + 0.8 * d)).clamp(0.0, 1.0)
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

fn terms_for(case: &Case) -> Terms {
    let mut t = Terms::default();
    t.configure(&configs(), case.seed);
    t.set_conditions(&case.conditions);
    // синтетика идёт с `air_model.enabled = off`: упрощённый профиль (README фикстур)
    t.wind.set_simple_profile(true, None);
    t.statics = case.static_thermals.clone();
    t.statics_mode = case.static_mode;
    t.focuses = case.focuses.clone();
    t.set_thermal_ground(Arc::new(SynGround));
    t
}

fn case_terms(name: &str) -> (Case, Terms) {
    let p = repo().join(format!("tests/fixtures/wind/cases/{name}.json"));
    let case = fixtures::read_case(&p).unwrap();
    let t = terms_for(&case);
    (case, t)
}

fn dump() -> Value {
    let p = repo().join("rust/dp-air/tests/data/RW-11f/cloud_objects.json");
    serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
}

/// Моменты дампа: (случай, момент, t записи, записи (полный id, 22 поля)).
type Shot = (String, f64, f64, Vec<(i64, Vec<f32>)>);

fn shots() -> Vec<Shot> {
    let d = dump();
    let mut out = Vec::new();
    for (name, moments) in d["cases"].as_object().unwrap() {
        for m in moments.as_array().unwrap() {
            for s in m["shots"].as_array().unwrap() {
                let recs = s["records"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|r| {
                        (
                            r["full_id"].as_i64().unwrap(),
                            r["rec"]
                                .as_array()
                                .unwrap()
                                .iter()
                                .map(|v| v.as_f64().unwrap() as f32)
                                .collect(),
                        )
                    })
                    .collect();
                out.push((
                    name.clone(),
                    m["t"].as_f64().unwrap(),
                    s["t"].as_f64().unwrap(),
                    recs,
                ));
            }
        }
    }
    out
}

fn close(a: f32, b: f32) -> bool {
    (a - b).abs() <= 1.0e-4 * b.abs().max(1.0)
}

const ALL: [f32; 3] = [0.0; 3];

/// (1) Записи против дампа GD: число, порядок по id, значения 1e-4 отн., `id & 0xFFFFFF`.
#[test]
fn records_match_gd_dump() {
    let mut total = 0;
    let mut cb = 0;
    let mut stat = 0;
    let mut past = 0;
    for (name, tm, tq, gd) in shots() {
        let (_, mut t) = case_terms(&name);
        t.start_at(tm);
        let mine = cloud_objects(&t, ALL, -1.0, tq);
        assert_eq!(mine.len(), gd.len(), "{name} t={tm} tq={tq}: число облаков");
        for (m, (full_id, g)) in mine.iter().zip(&gd) {
            assert_eq!(g.len(), OBJ_STRIDE);
            let a = m.to_array();
            let who = format!("{name} t={tm} tq={tq} id {full_id}");
            assert_eq!(a[0], (*full_id & 0xFF_FFFF) as f32, "{who}: id");
            for k in 1..OBJ_STRIDE {
                assert!(
                    close(a[k], g[k]),
                    "{who}: поле {k}: rust {}, gd {}",
                    a[k],
                    g[k]
                );
            }
            total += 1;
            cb += usize::from(g[1] as u32 & 4 != 0);
            stat += usize::from(g[1] as u32 & 1 != 0);
            past += usize::from(tq < tm);
        }
    }
    assert!(total >= 30, "сверено записей {total}");
    assert!(cb >= 3, "Cb {cb}");
    let _ = stat; // статичные термики синтетики без облака: ветка статичных - только по контракту
    assert!(past >= 10, "в прошлых моментах {past}");
}

/// (2) `id` уникален, порядок по возрастанию исходного id, младшие 24 бита.
#[test]
fn ids_unique_and_ordered() {
    let mut n = 0;
    for (name, tm, _, _) in shots().into_iter().filter(|s| s.1 == s.2) {
        let (_, mut t) = case_terms(&name);
        t.start_at(tm);
        let v = cloud_objects(&t, ALL, -1.0, tm);
        let mut seen = std::collections::HashSet::new();
        for r in &v {
            assert!(r.id >= 0.0 && r.id < 16_777_216.0);
            assert!(
                seen.insert(r.id as u32),
                "{name} t={tm}: id {} повторён",
                r.id
            );
        }
        n += v.len();
    }
    assert!(n >= 10);
}

/// (3) `radius < 0` - без ограничения; конечный радиус - подмножество по центру облака.
#[test]
fn radius_filters_by_cloud_center() {
    let (_, mut t) = case_terms("synth_storm");
    t.start_at(3600.0);
    let all = cloud_objects(&t, ALL, -1.0, 3600.0);
    assert!(all.len() >= 2);
    let c = [all[0].cx, 0.0, all[0].cz];
    let near = cloud_objects(&t, c, 1.0, 3600.0);
    assert!(!near.is_empty() && near.len() <= all.len());
    let want = all
        .iter()
        .filter(|r| f64::from(c[0] - r.cx).hypot(f64::from(c[2] - r.cz)) <= 1.0)
        .count();
    assert_eq!(near.len(), want);
    let none = cloud_objects(&t, [1.0e7, 0.0, 1.0e7], 100.0, 3600.0);
    assert!(none.is_empty());
}

/// (4) Прошлые моменты окна: облако вне окна жизни не отдаётся, внутри - растёт со временем.
#[test]
fn past_window_differs() {
    let mut moved = false;
    for name in ["synth_medium", "synth_storm"] {
        for tm in [900.0, 3600.0] {
            let (_, mut t) = case_terms(name);
            t.start_at(tm);
            let now = cloud_objects(&t, ALL, -1.0, tm);
            let back = cloud_objects(&t, ALL, -1.0, tm - 60.0);
            moved |= now.iter().any(|a| {
                back.iter().any(|b| {
                    a.id == b.id && (a.growth != b.growth || a.cx != b.cx || a.decay != b.decay)
                })
            });
            let early = cloud_objects(&t, ALL, -1.0, -1.0e6);
            assert!(
                early.iter().all(|r| r.flags as u32 & 1 != 0),
                "до рождения - только статичные"
            );
        }
    }
    assert!(moved, "записи на t и t - 60 одинаковы");
}

/// (5) `Core.storm` Cb = `storm_k` записи; не Cb - 0, у не-Cb `storm_t0 = storm_k = 0`.
#[test]
fn core_storm_equals_storm_k() {
    let mut cb = 0;
    let mut live = 0;
    for tm in [0.0, 900.0, 3600.0] {
        let (_, mut t) = case_terms("synth_storm");
        t.start_at(tm);
        let recs = cloud_objects(&t, ALL, -1.0, tm);
        for r in recs.iter().filter(|r| r.flags as u32 & 4 == 0) {
            assert_eq!((r.storm_t0, r.storm_k), (0.0, 0.0));
        }
        let mut cores: Vec<Core> = Vec::new();
        t.thermal_cores([1500.0, 0.0, -2500.0], 8000.0, tm, &mut cores);
        for c in &cores {
            if c.flags as u32 & 4 == 0 {
                assert_eq!(c.storm, 0.0);
                continue;
            }
            // ядро может быть без облака (рост): сверяем там, где запись есть
            if let Some(r) = recs.iter().find(|r| r.id == c.id) {
                assert!((c.storm - r.storm_k).abs() <= 1.0e-6, "t={tm} Cb {}", c.id);
                cb += 1;
                live += usize::from(c.storm > 0.1);
            }
        }
    }
    assert!(cb >= 2 && live >= 1, "Cb {cb}, с бурей {live}");
}

/// (6) Нет набора термиков - пусто; `out` очищается.
#[test]
fn empty_without_thermals() {
    let t = Terms::default();
    assert!(cloud_objects(&t, ALL, -1.0, 0.0).is_empty());
    let mut v = vec![ObjRecord::default()];
    dp_air::terms::objects::cloud_objects_into(&t, ALL, -1.0, 0.0, &mut v);
    assert!(v.is_empty());
    let _ = terms::SumCfg::default();
}
