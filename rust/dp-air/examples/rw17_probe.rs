//! RW-17: микропроба цены кандидатов (arc-swap, glam, rand_pcg, jiff). Только std и dp_air; крейты-кандидаты
//! здесь не подключены — их сторона замерена во временном крейте вне репозитория (см. rw17-crates.md).
//! Запуск: `cargo run --release -p dp-air --example rw17_probe`.
use dp_air::compat::rng::Pcg32;
use std::hint::black_box;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

struct P {
    v: Vec<u64>,
}

/// Снимок поля как в `formula.rs::Shared::snapshot`: `RwLock<Arc<_>>`, read + clone.
fn snapshot(readers: usize) -> f64 {
    let rw = RwLock::new(Arc::new(P { v: vec![1; 8] }));
    let stop = AtomicBool::new(false);
    let n = 2_000_000u64;
    let t = std::thread::scope(|s| {
        let w = s.spawn(|| {
            while !stop.load(Ordering::Relaxed) {
                *rw.write().unwrap() = Arc::new(P { v: vec![2; 8] });
                std::thread::sleep(Duration::from_micros(200));
            }
        });
        let hs: Vec<_> = (0..readers)
            .map(|_| {
                s.spawn(|| {
                    let t0 = Instant::now();
                    let mut a = 0u64;
                    for _ in 0..n {
                        a = a.wrapping_add(rw.read().unwrap().clone().v[0]);
                    }
                    black_box(a);
                    t0.elapsed()
                })
            })
            .collect();
        let tot: Duration = hs.into_iter().map(|h| h.join().unwrap()).sum();
        stop.store(true, Ordering::Relaxed);
        w.join().unwrap();
        tot / readers as u32
    });
    t.as_nanos() as f64 / n as f64
}

fn main() {
    for r in [1, 8] {
        println!("snapshot RwLock<Arc> readers={r}: {:.1} ns/op", snapshot(r));
    }
    let n = 50_000_000u32;
    let t = Instant::now();
    let mut g = Pcg32::from_seed(1);
    let mut a = 0u32;
    for _ in 0..n {
        a ^= g.randi();
    }
    black_box(a);
    println!("Pcg32::randi: {:.2} ns", t.elapsed().as_nanos() as f64 / f64::from(n));
    let t = Instant::now();
    let mut a = 0u64;
    for i in 0..1_000_000u64 {
        a += u64::from(Pcg32::from_seed(i).randi());
    }
    black_box(a);
    println!("Pcg32::from_seed+randi: {:.1} ns", t.elapsed().as_nanos() as f64 / 1e6);
    let d: [i64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let t = Instant::now();
    let mut a = 0i64;
    for i in 0..10_000_000i64 {
        let m = i % 12 + 1;
        a += i % 28 + 1 + d[..(m - 1) as usize].iter().sum::<i64>();
    }
    black_box(a);
    println!("day_of_year: {:.2} ns", t.elapsed().as_nanos() as f64 / 1e7);
}
