//! Базовая линия на заглушке `Calm` (профиль release): `sample_many` 18 и 1000 точек, `advance_to`.
//! Медианы в baseline.json собирает `collect_baseline.py` после `cargo bench`.
use criterion::{Criterion, black_box, criterion_group, criterion_main};
use dp_air::{AirModel, Calm, Place, PlaceHeader, SampleMode};

const HEADER: &str = r#"{"version":1,"loc":{"id":"bench","center_lat":50.0,"center_lon":86.0,
"utc_offset_h":7.0,"month":7,"day":1},"grid":{"origin_x":0,"origin_z":0,"spacing":25,
"width":4,"height":4},"surface_classes":{},"start_sites":[]}"#;

fn ready() -> Calm {
    let h = PlaceHeader::from_json(HEADER).unwrap();
    let p = Place::new(h, vec![0.0; 16], vec![0; 16], vec![0; 16], vec![0.0; 16]).unwrap();
    let mut m = Calm::new();
    m.load_place(p).unwrap();
    m
}

fn points(n: usize) -> Vec<[f32; 3]> {
    (0..n)
        .map(|i| [i as f32 * 3.0, 500.0 + i as f32, -(i as f32) * 2.0])
        .collect()
}

fn benches(c: &mut Criterion) {
    let m = ready();
    for n in [18usize, 1000] {
        let pts = points(n);
        let mut out = vec![[0.0f32; 4]; n];
        c.bench_function(&format!("sample_many_{n}"), |b| {
            b.iter(|| m.sample_many(black_box(&pts), SampleMode::Full, black_box(&mut out)))
        });
    }
    let mut m = ready();
    let mut t = 0.0f64;
    c.bench_function("advance_to", |b| {
        b.iter(|| {
            t += 0.016;
            m.advance_to(black_box(t)).unwrap()
        })
    });
}

criterion_group!(g, benches);
criterion_main!(g);
