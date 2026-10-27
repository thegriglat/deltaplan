//! Скорость `Formula` (W8, «Скорость»; профиль release W9): `sample_many` 18 и 1000 точек и
//! `advance_to` в `Ready` — без окон клипмапа (одна область) и с окнами 100/50 м (три уровня).
//! Пороги W8: 18 точек ≤ 50 мкс, 1000 ≤ 2 мс, `advance_to` ≤ 0,5 мс; регрессия > 20 % от
//! `baseline.json` — FAIL. Медианы собирает `collect_baseline.py Formula` после `cargo bench`.
//!
//! Поле — синтетика (`tests/fixtures/wind/places/synthetic`), область 12 км, `tol_scale` 5, режим
//! притока `inflow` (один проход): настройка не входит в замер, цена опроса от размера области не
//! зависит (уровни те же, считается билинейно по клеткам). `advance_to` в покое — проверка срока
//! пересчёта и сдвига окон без запуска задачи: время растёт на микросекунды, срок
//! `recompute_game_min` не наступает.
use criterion::{Criterion, black_box, criterion_group, criterion_main};
use dp_air::field::runtime::ground_height;
use dp_air::fixtures::read_place;
use dp_air::{AirModel, Conditions, Configs, Focus, Formula, SampleMode, State};
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

fn configs(windows: bool) -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere.json" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = json!(false);
            v["air"]["domain_l_m"] = json!(12000.0);
            v["air"]["threads"] = json!(4);
            v["air"]["tol_scale"] = json!(5.0);
            v["air"]["timeout_s"] = json!(900.0);
            if !windows {
                v["air_model"]["window_levels_m"] = json!([]);
            }
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

/// `Formula` в `Ready` с полем; `windows` — с окнами клипмапа (нужен фокус).
fn ready(windows: bool) -> Formula {
    let pl = read_place(&repo().join("tests/fixtures/wind/places/synthetic.json")).unwrap();
    let c = Conditions::from_json(
        r#"{"preset":"medium","start_hour":12,"speed":1,"blend_s":null,"rebuild":false,"inflow_mode":"inflow"}"#,
    )
    .unwrap();
    let mut m = Formula::new();
    m.configure(&configs(windows), 1).unwrap();
    m.set_conditions(&c).unwrap();
    m.set_focuses(&[Focus {
        pos: [0.0, ground_height(&pl, 0.0, 0.0) + 10.0, 0.0],
        weight: 1.0,
    }])
    .unwrap();
    m.load_place(pl).unwrap();
    let t0 = Instant::now();
    while m.status().state != State::Ready {
        assert!(
            t0.elapsed() < Duration::from_secs(900),
            "поле не посчиталось"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    m.poll();
    assert_eq!(m.level_count(), if windows { 3 } else { 1 });
    m
}

/// Точки вокруг центра (внутри окон 50 и 100 м — ближние), высоты 3…800 м над землёй — всегда в
/// поле, не на запасном пути за его пределами.
fn points(n: usize) -> Vec<[f32; 3]> {
    let pl = read_place(&repo().join("tests/fixtures/wind/places/synthetic.json")).unwrap();
    (0..n)
        .map(|i| {
            let a = i as f32 * 2.399_963;
            let r = 20.0 + 1500.0 * ((i % 37) as f32 / 37.0);
            let (x, z) = (r * a.cos(), r * a.sin());
            let agl = [3.0, 30.0, 100.0, 300.0, 800.0][i % 5];
            [x, ground_height(&pl, x, z) + agl, z]
        })
        .collect()
}

fn benches(c: &mut Criterion) {
    for (windows, tag) in [(false, ""), (true, "_win")] {
        let mut m = ready(windows);
        for n in [18usize, 1000] {
            let pts = points(n);
            let mut out = vec![[0.0f32; 4]; n];
            c.bench_function(&format!("formula_sample_many_{n}{tag}"), |b| {
                b.iter(|| m.sample_many(black_box(&pts), SampleMode::Full, black_box(&mut out)))
            });
        }
        let mut t = 0.0f64;
        c.bench_function(&format!("formula_advance_to{tag}"), |b| {
            b.iter(|| {
                t += 1.0e-6;
                m.advance_to(black_box(t)).unwrap()
            })
        });
    }
}

criterion_group!(g, benches);
criterion_main!(g);
