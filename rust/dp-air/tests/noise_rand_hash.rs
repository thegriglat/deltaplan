//! RW-8c: шум, генератор и хеши сверяются с дампом, снятым в Godot
//! (`tools/wind_fixtures/compat_dump.sh`, данные — `tests/data/godot_compat/`).

use dp_air::hash::{hash_v2i, hash_v3i};
use dp_air::noise::{FastNoise, Fractal};
use dp_air::rand::Pcg32;
use std::path::PathBuf;

const NOISE_SEEDS: [i32; 4] = [0, 1, 20_260_927, 20_260_927 + 7919];
const RNG_SEEDS: [i64; 9] = [
    0,
    1,
    42,
    7919,
    20_260_927,
    2_147_483_647,
    4_294_967_295,
    3_405_691_582,
    -1,
];

fn read(name: &str) -> Vec<u8> {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data/godot_compat")
        .join(name);
    std::fs::read(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

fn f32s(name: &str) -> Vec<f32> {
    read(name)
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
        .collect()
}

fn u32s(name: &str) -> Vec<u32> {
    read(name)
        .chunks_exact(4)
        .map(|c| u32::from_le_bytes(c.try_into().unwrap()))
        .collect()
}

fn i32s(name: &str) -> Vec<i32> {
    u32s(name).into_iter().map(|v| v as i32).collect()
}

fn noise_max_diff(kind: &str, fractal: Fractal, frequency: f32) -> f32 {
    let pts = f32s("noise_pts.f32");
    let mut worst = 0.0f32;
    let mut n = 0;
    for seed in NOISE_SEEDS {
        let want = f32s(&format!("noise_{seed}_{kind}.f32"));
        let fnl = FastNoise::new(seed, fractal, frequency);
        assert_eq!(want.len() * 3, pts.len());
        for (i, w) in want.iter().enumerate() {
            let g = fnl.get3(pts[i * 3], pts[i * 3 + 1], pts[i * 3 + 2]);
            worst = worst.max((g - w).abs());
            n += 1;
        }
    }
    println!("noise {kind}: {n} значений, max|d| = {worst:e}");
    worst
}

#[test]
fn noise_none() {
    let d = noise_max_diff("none", Fractal::None, 1.0);
    assert!(d <= 1e-6, "max|d| = {d:e}");
}

#[test]
fn noise_fbm_2_octaves() {
    let f = Fractal::Fbm {
        octaves: 2,
        gain: 0.5,
        lacunarity: 2.0,
        weighted_strength: 0.0,
    };
    let d = noise_max_diff("fbm2", f, 1.0);
    assert!(d <= 1e-6, "max|d| = {d:e}");
}

#[test]
fn noise_fbm_weighted_other_params() {
    let f = Fractal::Fbm {
        octaves: 4,
        gain: 0.6,
        lacunarity: 1.9,
        weighted_strength: 0.5,
    };
    let d = noise_max_diff("fbm4w", f, 0.7);
    assert!(d <= 1e-6, "max|d| = {d:e}");
}

#[test]
fn rng_randf_exact() {
    for s in RNG_SEEDS {
        let want = f32s(&format!("rng_{s}_randf.f32"));
        let mut r = Pcg32::from_seed(s as u64);
        for (i, w) in want.iter().enumerate() {
            assert_eq!(r.randf().to_bits(), w.to_bits(), "seed {s}, #{i}");
        }
    }
}

#[test]
fn rng_randf_range_exact() {
    for s in RNG_SEEDS {
        let want = f32s(&format!("rng_{s}_range.f32"));
        let mut r = Pcg32::from_seed(s as u64);
        for (i, w) in want.iter().enumerate() {
            assert_eq!(
                r.randf_range(-5000.0, 5000.0).to_bits(),
                w.to_bits(),
                "seed {s}, #{i}"
            );
        }
    }
}

#[test]
fn rng_randi_exact() {
    for s in RNG_SEEDS {
        let want = u32s(&format!("rng_{s}_randi.u32"));
        let mut r = Pcg32::from_seed(s as u64);
        for (i, w) in want.iter().enumerate() {
            assert_eq!(r.randi(), *w, "seed {s}, #{i}");
        }
    }
}

#[test]
fn rng_mixed_stream_exact() {
    for s in RNG_SEEDS {
        let f = f32s(&format!("rng_{s}_mix.f32"));
        let u = u32s(&format!("rng_{s}_mixi.u32"));
        let mut r = Pcg32::from_seed(s as u64);
        for (i, w) in u.iter().enumerate() {
            assert_eq!(
                r.randf().to_bits(),
                f[i * 3].to_bits(),
                "seed {s}, #{i} randf"
            );
            assert_eq!(
                r.randf_range(100.0, 200.0).to_bits(),
                f[i * 3 + 1].to_bits(),
                "seed {s}, #{i} range"
            );
            assert_eq!(
                r.randf_range(-1.0, 1.0).to_bits(),
                f[i * 3 + 2].to_bits(),
                "seed {s}, #{i} range2"
            );
            assert_eq!(r.randi(), *w, "seed {s}, #{i} randi");
        }
    }
}

#[test]
fn hash_v2i_exact() {
    let inp = i32s("hash2_in.i32");
    let want = u32s("hash2_out.u32");
    assert_eq!(inp.len(), want.len() * 2);
    for (i, w) in want.iter().enumerate() {
        assert_eq!(hash_v2i(inp[i * 2], inp[i * 2 + 1]), *w, "#{i}");
    }
}

#[test]
fn hash_v3i_exact() {
    let inp = i32s("hash3_in.i32");
    let want = u32s("hash3_out.u32");
    assert_eq!(inp.len(), want.len() * 3);
    for (i, w) in want.iter().enumerate() {
        assert_eq!(
            hash_v3i(inp[i * 3], inp[i * 3 + 1], inp[i * 3 + 2]),
            *w,
            "#{i}"
        );
    }
}
