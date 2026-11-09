//! TB-7: шаблон пузыря в `dp-air` за флагом `thermal.bubble_template` (контракт TB4 v1).
//!
//! `flag_off_bitwise` — флаг выкл: `State::sample` и `terms::sum` побитно как до модуля (фикстура
//! `tests/data/thermal_bubble_off.json`, записана на нетронутом коде: `TB_RECORD=1`).
#![allow(clippy::needless_range_loop)]
use dp_air::field::field_set::FieldSet;
use dp_air::terms::thermal::{AtmoThermal, GroundSource, NoClouds};
use dp_air::terms::{self, Terms};
use dp_air::{Conditions, Configs, Focus, Place, PlaceHeader, SampleMode};
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

struct Sunny;
impl GroundSource for Sunny {
    fn height(&self, _x: f64, _z: f64) -> f64 {
        0.0
    }
    fn source(&self, _x: f64, _z: f64, _t: f64) -> f64 {
        1.0
    }
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

/// Сильный день на ровной земле со сносом (ветер 18 км/ч), динамические термики, круг генерации 8 км.
fn scene_terms(patch: impl Fn(&mut Value)) -> Terms {
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
    t.set_thermal_ground(Arc::new(Sunny));
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

/// Живые активные термики набора (по возрастанию id), у которых на момент `t` есть подъём.
fn live(t: &Terms, tm: f64, n: usize) -> Vec<Arc<AtmoThermal>> {
    let st = t.slots.thermal.as_slot().unwrap().state().unwrap();
    let mut v: Vec<Arc<AtmoThermal>> = st
        .active
        .iter()
        .filter(|h| !h.is_static && h.phase(tm).env > 0.3 && h.strength > 1.5)
        .cloned()
        .collect();
    v.sort_by_key(|h| h.id);
    v.truncate(n);
    v
}

/// Точки вокруг термика: цилиндр радиусом 3 радиуса ядра, от земли источника до верха.
fn points_around(h: &AtmoThermal, tm: f64, rng: &mut Rng, n: usize) -> Vec<[f32; 3]> {
    let ph = h.phase(tm);
    let y0 = f64::from(h.src[1]);
    (0..n)
        .map(|_| {
            let y = y0 + 20.0 + rng.next() * (h.top - y0 + 80.0);
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

const MOMENTS: [f64; 3] = [700.0, 1600.0, 2600.0];
const PER_THERMAL: usize = 170;

/// Побитовая запись `State::sample` (u64) и `sum` (u32) на сцене флага выкл.
fn record(t: &mut Terms, place: &Place) -> Value {
    let fs = FieldSet::default();
    let mut moments = Vec::new();
    for (mi, &tm) in MOMENTS.iter().enumerate() {
        t.start_at(tm);
        let ths = live(t, tm, 6);
        assert!(ths.len() >= 5, "живых термиков {} в момент {tm}", ths.len());
        let slot = t.slots.thermal.as_slot().unwrap();
        let (st, setup) = (slot.state().unwrap(), slot.setup().unwrap());
        let mut rng = Rng(100 + mi as u64);
        let (mut pts, mut samp, mut sums) = (Vec::new(), Vec::new(), Vec::new());
        for h in &ths {
            for p in points_around(h, tm, &mut rng, PER_THERMAL) {
                let o = st.sample(setup, &NoClouds, p, tm);
                let s = terms::sum(t, &fs, Some(place), p, SampleMode::Mean, tm, None);
                pts.push(json!([p[0].to_bits(), p[1].to_bits(), p[2].to_bits()]));
                samp.push(json!([o[0].to_bits(), o[1].to_bits(), o[2].to_bits()]));
                sums.push(json!([
                    s[0].to_bits(),
                    s[1].to_bits(),
                    s[2].to_bits(),
                    s[3].to_bits()
                ]));
            }
        }
        moments.push(json!({
            "t": tm,
            "ids": ths.iter().map(|h| h.id).collect::<Vec<_>>(),
            "points": pts, "sample": samp, "sum": sums,
        }));
    }
    json!({"per_thermal": PER_THERMAL, "moments": moments})
}

fn fixture_path() -> PathBuf {
    repo().join("rust/dp-air/tests/data/thermal_bubble_off.json")
}

/// Флаг выкл: те же биты, что до модуля. `TB_RECORD=1` — переписать фикстуру (только на нетронутом коде).
#[test]
fn flag_off_bitwise() {
    let place = flat_place();
    let mut t = scene_terms(|_| {});
    let now = record(&mut t, &place);
    if std::env::var("TB_RECORD").is_ok() {
        std::fs::write(fixture_path(), serde_json::to_string(&now).unwrap()).unwrap();
        return;
    }
    let want: Value = serde_json::from_str(&std::fs::read_to_string(fixture_path()).unwrap()).unwrap();
    let (a, b) = (now["moments"].as_array().unwrap(), want["moments"].as_array().unwrap());
    assert_eq!(a.len(), b.len());
    let mut n = 0;
    for (m, (x, y)) in a.iter().zip(b).enumerate() {
        assert_eq!(x["ids"], y["ids"], "момент {m}: набор термиков");
        assert_eq!(x["points"], y["points"], "момент {m}: точки");
        for key in ["sample", "sum"] {
            let (xs, ys) = (x[key].as_array().unwrap(), y[key].as_array().unwrap());
            for (i, (p, q)) in xs.iter().zip(ys).enumerate() {
                assert_eq!(p, q, "момент {m} {key} #{i}: биты");
                n += 1;
            }
        }
    }
    assert!(n >= 2 * 1000 * MOMENTS.len(), "сверено {n}");
}
