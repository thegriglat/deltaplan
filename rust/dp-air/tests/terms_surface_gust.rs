//! RW-8s: поверхностный порыв `surface_gust_many` против `GustDustModel.gust_ms` (ревизия `c591b1026`,
//! `tests/data/RW-8s/`).
use dp_air::Configs;
use dp_air::terms::Terms;
use dp_air::terms::WeatherView;
use dp_air::terms::surface_gust::{GustDustCfg, surface_gust_many};
use serde_json::{Map, Value, json};
use std::path::PathBuf;
use std::sync::Arc;

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn data_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/data/RW-8s")
}

fn configs() -> Arc<Configs> {
    let t = std::fs::read_to_string(repo().join("configs/atmosphere.json")).unwrap();
    Arc::new(Configs::new(vec![("atmosphere".into(), t)]))
}

fn terms_for(seed: u64, speed: f64, from: f64, sun: f64, cover: f64, conv: f64) -> Terms {
    let mut t = Terms::default();
    t.configure(&configs(), seed);
    t.wind.set_wind(speed, from);
    t.wind.set_conditions(sun, cover);
    let mut m = Map::new();
    m.insert("convective_turbulence_ms".into(), json!(conv));
    t.weather = WeatherView::new(m);
    t
}

struct Scen {
    name: String,
    head: [f64; 6],
    rec: Vec<[f64; 4]>,
}

fn load() -> Vec<Scen> {
    let man: Value =
        serde_json::from_str(&std::fs::read_to_string(data_dir().join("manifest.json")).unwrap())
            .unwrap();
    let n = man["n"].as_u64().unwrap() as usize;
    let buf: Vec<f64> = std::fs::read(data_dir().join("gust_dump.f64"))
        .unwrap()
        .chunks_exact(8)
        .map(|c| f64::from_le_bytes(c.try_into().unwrap()))
        .collect();
    man["scenarios"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            let o = s["offset"].as_u64().unwrap() as usize;
            let head: [f64; 6] = buf[o..o + 6].try_into().unwrap();
            let rec = buf[o + 6..o + 6 + 4 * n]
                .chunks_exact(4)
                .map(|c| [c[0], c[1], c[2], c[3]])
                .collect();
            Scen {
                name: s["name"].as_str().unwrap().into(),
                head,
                rec,
            }
        })
        .collect()
}

fn run(s: &Scen) -> (Vec<f32>, f64) {
    let h = s.head;
    let t = terms_for(h[0] as u64, h[1], h[2], h[3], h[4], h[5]);
    let xz: Vec<[f32; 2]> = s.rec.iter().map(|r| [r[0] as f32, r[1] as f32]).collect();
    let ts: Vec<f64> = s.rec.iter().map(|r| r[2]).collect();
    let mut out = vec![0.0f32; xz.len()];
    surface_gust_many(&t, &xz, &ts, &mut out);
    let worst = out
        .iter()
        .zip(&s.rec)
        .map(|(a, r)| (f64::from(*a) - r[3]).abs())
        .fold(0.0, f64::max);
    (out, worst)
}

/// Против GD на случайных (x, z, t) - синтетика и сиды/ветер Онгудая; допуск W8: |Δv| <= 0,05 м/с + 2 %.
#[test]
fn matches_godot_gust_ms() {
    for s in load() {
        let (out, worst) = run(&s);
        let var = out
            .iter()
            .map(|v| f64::from(*v))
            .fold((0.0, 0.0), |a, v| (a.0 + v, a.1 + v * v));
        println!(
            "{}: {} точек, max|Δ| = {worst:e} м/с (среднее {:.3}, rms {:.3})",
            s.name,
            out.len(),
            var.0 / out.len() as f64,
            (var.1 / out.len() as f64).sqrt()
        );
        for (a, r) in out.iter().zip(&s.rec) {
            let tol = 0.05 + 0.02 * r[3].abs();
            assert!(
                (f64::from(*a) - r[3]).abs() <= tol,
                "{}: {a} против {}",
                s.name,
                r[3]
            );
        }
        // шум GD побитно; f32 на выходе - округление до f32
        assert!(
            worst < 1.0e-5,
            "{}: ожидали ~побитно, max|Δ| = {worst}",
            s.name
        );
    }
}

/// Порыв - чистая функция (x, z, t): прошлые t, повтор и порядок точек не влияют; порыв не отрицателен.
#[test]
fn pure_in_x_z_t_and_nonnegative() {
    let t = terms_for(606, 8.0, 151.0, 52.0, 0.0, 1.0);
    let xz = [[100.0f32, -250.0], [4000.0, 3000.0], [-17.0, 5.5]];
    let ts = [10.0, 7000.0, 0.0];
    let mut a = [0.0f32; 3];
    surface_gust_many(&t, &xz, &ts, &mut a);
    let mut b = [0.0f32; 3];
    for i in (0..3).rev() {
        surface_gust_many(&t, &xz[i..=i], &ts[i..=i], &mut b[i..=i]);
    }
    assert_eq!(a, b);
    // «прошлый» слот: t на 24 с назад
    let mut c = [0.0f32; 1];
    surface_gust_many(&t, &xz[..1], &[10.0 - 24.0], &mut c);
    assert!(c[0] >= 0.0 && c[0].is_finite());
    // сильные пульсации не уводят ветер в минус
    let w = terms_for(7, 2.0, 0.0, 52.0, 0.0, 6.0);
    let n = 400;
    let xz: Vec<[f32; 2]> = (0..n)
        .map(|i| [i as f32 * 37.0, i as f32 * -11.0])
        .collect();
    let ts: Vec<f64> = (0..n).map(|i| i as f64 * 1.7).collect();
    let mut o = vec![-1.0f32; n];
    surface_gust_many(&w, &xz, &ts, &mut o);
    assert!(o.iter().all(|v| *v >= 0.0));
    assert!(o.contains(&0.0), "ожидали и срез на 0 при σ ≫ u");
}

/// Нечисловой вход - 0; длины по минимуму, остаток `out` не трогается; штиль и σ=0 - ровно u.
#[test]
fn bad_input_lengths_and_calm() {
    let t = terms_for(606, 6.0, 90.0, 52.0, 0.0, 1.0);
    let xz = [
        [f32::NAN, 0.0],
        [0.0, f32::INFINITY],
        [1.0, 2.0],
        [3.0, 4.0],
    ];
    let ts = [0.0, 0.0, f64::NAN, 5.0];
    let mut o = [7.0f32; 6];
    surface_gust_many(&t, &xz, &ts, &mut o);
    assert_eq!(&o[..3], &[0.0, 0.0, 0.0]);
    assert!(o[3] > 0.0 && o[3].is_finite());
    assert_eq!(&o[4..], &[7.0, 7.0], "дальше min длин - не трогаем");
    let mut short = [7.0f32; 2];
    surface_gust_many(&t, &xz, &ts, &mut short);
    assert_eq!(short, [0.0, 0.0]);
    let mut none: [f32; 0] = [];
    surface_gust_many(&t, &xz, &ts, &mut none);
    // штиль: u = 0, σ = conv_k·conv > 0, но порыв не отрицателен
    let calm = terms_for(606, 0.0, 90.0, 52.0, 0.0, 0.0);
    let mut c = [1.0f32; 2];
    surface_gust_many(&calm, &[[5.0, 5.0], [90.0, 1.0]], &[1.0, 2.0], &mut c);
    assert_eq!(c, [0.0, 0.0]);
}

/// Константы читаются из `gust_dust` конфига.
#[test]
fn constants_from_config() {
    let c = GustDustCfg::from_configs(&configs());
    assert_eq!(
        c,
        GustDustCfg {
            sigma_frac: 0.25,
            conv_k: 0.5,
            large_k: 0.6
        }
    );
}
