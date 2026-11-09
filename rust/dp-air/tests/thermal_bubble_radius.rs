//! TB-13: радиус пузырей `thermal.bubble_radius_m` (2000 м) — шов и цена.
//!
//! `radius_seam` — одиночный динамический термик подвинут к фокусу так, чтобы его режим сменился (профиль → таблица
//! пузыря); сравниваются два состояния набора на одних и тех же точках: максимум разрыва `w`/`uh` в момент смены
//! (`seam_dw_max_ms=`), расстояние от фокуса до ближайшей точки, где модели различаются (`seam_dist_min_m=`).
//! `radius_cost` — цена сборки/память/число таблиц на сцене плотности Аллена при радиусе 1000…6000 м (печатает строки
//! `RADJSON {...}`, их собирает `tools/research/thermal_bubble/round3/radius.py`).
//! Запуск: `cargo test --manifest-path rust/Cargo.toml -p dp-air --release --test thermal_bubble_radius -- --nocapture`.
#![allow(clippy::needless_range_loop)]
use dp_air::terms::thermal::bubble::{self, BubbleCache};
use dp_air::terms::thermal::{AtmoThermal, GroundSource, NoClouds, Setup, State};
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

struct Spot;
impl GroundSource for Spot {
    fn height(&self, _x: f64, _z: f64) -> f64 {
        0.0
    }
    fn source(&self, x: f64, z: f64, _t: f64) -> f64 {
        if x.hypot(z) < 800.0 { 1.0 } else { 0.0 }
    }
}

/// `Setup` игры (погода strong, ветер 18 км/ч с запада) и радиусом пузырей `radius_m`.
fn setup_with(radius_m: f64) -> Arc<Setup> {
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
        v["thermal"]["bubble_radius_m"] = json!(radius_m);
    });
    let mut t = Terms::default();
    t.configure(&cfg, 4242);
    t.thermal_async = false;
    t.set_conditions(&c);
    t.focuses = vec![Focus {
        pos: [0.0, 0.0, 0.0],
        weight: 1.0,
    }];
    t.set_thermal_ground(Arc::new(Spot));
    t.start_at(1200.0);
    t.slots.thermal.as_slot().unwrap().setup().unwrap().clone()
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

/// Динамический термик игры: источник `(x, z)`, столб `zl`, сила `w0`, рождён в `t_birth`.
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

fn axis_xz(h: &AtmoThermal, tm: f64) -> [f64; 2] {
    let ph = h.phase(tm);
    [
        f64::from(h.src[0]) + f64::from(ph.drift[0]),
        f64::from(h.src[2]) + f64::from(ph.drift[1]),
    ]
}

/// Порог «модели различаются», м/с.
const DIFF_MS: f64 = 0.02;

/// Один случай шва: стадия жизни `tm`, сила `w0`. Печатает `RADJSON {"kind":"seam",…}` и возвращает
/// `(max |Δw|, max |uh|, ближайшая дистанция различия, радиус таблицы, X смены)`.
fn seam_case(setup: &Arc<Setup>, tm: f64, w0: f64) -> (f64, f64, f64, f64, f64) {
    let th = Arc::new(thermal_at(1, 0.0, 0.0, 1400.0, w0, 0.0));
    let c = axis_xz(&th, tm);
    let mode_table = |x: f64| -> bool {
        let st = State::build(setup, vec![th.clone()], tm, &[[c[0] + x, c[1]]], 1.0, 0);
        st.bubble_count() == 1
    };
    // двоичный поиск расстояния X (фокус на линии через ось по x), при котором режим меняется
    let (mut lo, mut hi) = (1000.0f64, 4500.0f64);
    assert!(mode_table(lo) && !mode_table(hi), "смена режима вне 1000…4500 м");
    for _ in 0..22 {
        let mid = 0.5 * (lo + hi);
        if mode_table(mid) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    let (x_in, x_out) = (lo, hi);
    let f_in = [c[0] + x_in, c[1]];
    let f_out = [c[0] + x_out, c[1]];
    let st_in = State::build(setup, vec![th.clone()], tm, &[f_in], 1.0, 0);
    let st_out = State::build(setup, vec![th.clone()], tm, &[f_out], 1.0, 0);
    assert_eq!(st_in.bubble_count(), 1);
    assert_eq!(st_out.bubble_count(), 0);
    // точки: высоты × кольца × углы, ось на каждой высоте
    let ph = th.phase(tm);
    let rhos = [
        0.0, 20.0, 50.0, 100.0, 150.0, 200.0, 300.0, 500.0, 800.0, 1200.0, 2000.0,
    ];
    let highs = [10.0, 80.0, 300.0, 700.0, 1100.0, 1380.0];
    let (mut dw_max, mut uh_max, mut d_min, mut n_pts) = (0.0f64, 0.0f64, f64::INFINITY, 0usize);
    let (mut w_prof_max, mut w_tab_max) = (0.0f64, 0.0f64);
    for &h in &highs {
        let ax = th.axis_at(h, ph.drift);
        for &rho in &rhos {
            for k in 0..8 {
                let a = std::f64::consts::TAU * f64::from(k) / 8.0;
                let p = [
                    (ax[0] + rho * a.cos()) as f32,
                    h as f32,
                    (ax[1] + rho * a.sin()) as f32,
                ];
                let (o_in, uh_in) = st_in.sample_bubble(setup, &NoClouds, p, tm);
                let (o_out, uh_out) = st_out.sample_bubble(setup, &NoClouds, p, tm);
                let dw = (o_in[0] - o_out[0]).abs();
                let duh = (uh_in[0] - uh_out[0]).hypot(uh_in[1] - uh_out[1]);
                dw_max = dw_max.max(dw);
                uh_max = uh_max.max(duh);
                w_prof_max = w_prof_max.max(o_out[0].abs());
                w_tab_max = w_tab_max.max(o_in[0].abs());
                n_pts += 1;
                // расстояние от фокуса (в режиме «внутри») до точки, где любая из двух моделей даёт вклад
                let any = o_in[0].abs() > DIFF_MS
                    || o_out[0].abs() > DIFF_MS
                    || uh_in[0].hypot(uh_in[1]) > DIFF_MS;
                if any {
                    let d = (f64::from(p[0]) - f_in[0]).hypot(f64::from(p[2]) - f_in[1]);
                    d_min = d_min.min(d);
                }
            }
        }
    }
    // сам пилот в момент смены
    let pilot = [f_in[0] as f32, 50.0, f_in[1] as f32];
    let (po_in, _) = st_in.sample_bubble(setup, &NoClouds, pilot, tm);
    let (po_out, _) = st_out.sample_bubble(setup, &NoClouds, pilot, tm);
    let pilot_dw = (po_in[0] - po_out[0]).abs();
    // радиус таблицы (влияния)
    let r_tab = {
        let (src, zi) = bubble::source_of(&th).unwrap();
        let b = bubble::state(&src, zi, tm).expect("пузырь есть");
        let bb = bubble::Bubble::for_table(b);
        bubble::influence_radius(&bb, zi, bubble::INFLUENCE_FRAC * w0).0
    };
    println!(
        "radius_seam: tm={tm:.0} w0={w0:.1} X_смены={x_in:.1}…{x_out:.1} м, точек {n_pts}, max|Δw|={dw_max:.3} \
         max|Δuh|={uh_max:.3} w_проф_max={w_prof_max:.3} w_табл_max={w_tab_max:.3} дистанция_до_различия_min={d_min:.0} \
         пилот Δw={pilot_dw:.3} r_табл={r_tab:.0}"
    );
    println!(
        "RADJSON {}",
        json!({"kind": "seam", "tm": tm, "w0": w0, "x_switch_m": x_in, "dw_max_ms": dw_max,
               "duh_max_ms": uh_max, "w_profile_max_ms": w_prof_max, "w_table_max_ms": w_tab_max,
               "dist_to_difference_min_m": d_min, "pilot_dw_ms": pilot_dw, "table_radius_m": r_tab, "n_points": n_pts})
    );
    (dw_max, uh_max, d_min, r_tab, x_in)
}

#[test]
fn radius_seam() {
    let setup = setup_with(2000.0);
    assert!((setup.cfg.bubble_radius_m - 2000.0).abs() < 1e-9);
    let (mut dw_all, mut uh_all, mut d_all) = (0.0f64, 0.0f64, f64::INFINITY);
    let mut r_all = 0.0f64;
    for &(tm, w0) in &[
        (150.0, 2.5),
        (400.0, 2.5),
        (700.0, 2.5),
        (900.0, 2.5),
        (400.0, 4.0),
        (700.0, 1.6),
    ] {
        let (dw, uh, d, r, _x) = seam_case(&setup, tm, w0);
        dw_all = dw_all.max(dw);
        uh_all = uh_all.max(uh);
        d_all = d_all.min(d);
        r_all = r_all.max(r);
    }
    println!("seam_dw_max_ms={dw_all:.3}");
    println!("seam_duh_max_ms={uh_all:.3}");
    println!("seam_dist_min_m={d_all:.0}");
    println!("seam_table_radius_max_m={r_all:.0}");
    println!(
        "RADJSON {}",
        json!({"kind": "seam_all", "dw_max_ms": dw_all, "duh_max_ms": uh_all,
               "dist_to_difference_min_m": d_all, "table_radius_max_m": r_all})
    );
    assert!(dw_all.is_finite() && uh_all.is_finite());
}

/// Размер всех таблиц в кеше, байт.
fn cache_bytes(cache: &BubbleCache) -> (usize, usize) {
    let c = cache.lock();
    let (mut bytes, mut n) = (0usize, 0usize);
    for e in c.values() {
        for (_, t) in &e.frames {
            if let Some(t) = t {
                bytes += t.bytes();
                n += 1;
            }
        }
    }
    (bytes, n)
}

/// Цена шаблона при радиусе пузырей 1000…6000 м: сцена плотности Аллена n_A = 8,5/z_l² (z_l 1400 м) на квадрате
/// ±9000 м, фокус летит 15 м/с, обновление раз в 1 с, один поток. Тот же счёт, что `bubble_cache_budget`
/// (`thermal_bubble_embed.rs`), для набора радиусов.
#[test]
#[cfg_attr(
    debug_assertions,
    ignore = "цена меряется в release: cargo test --release … radius_cost"
)]
fn radius_cost() {
    let zl = 1400.0;
    let n_a = 8.5 / (zl * zl);
    let half = 9000.0;
    let t0 = 1000.0;
    let steps = 40usize;
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(1)
        .build()
        .unwrap();
    let mut out = Vec::new();
    for &radius in &[0.0f64, 1000.0, 2000.0, 3000.0, 4000.0, 6000.0] {
        let setup = setup_with(radius.max(1.0));
        let mut rng = Rng(2026);
        let n = (n_a * 4.0 * half * half) as usize;
        let all: Vec<Arc<AtmoThermal>> = (0..n)
            .map(|i| {
                let x = (rng.next() * 2.0 - 1.0) * half;
                let z = (rng.next() * 2.0 - 1.0) * half;
                let w0 = 1.5 + 2.5 * rng.next();
                let life = 180.0 + 510.0 + 300.0;
                let mut h = thermal_at(i as i64 + 1, x as f32, z as f32, zl, w0, t0 - rng.next() * life);
                h.t_grow = 120.0 + 120.0 * rng.next();
                h.t_mature = 300.0 + 420.0 * rng.next();
                h.t_decay = 150.0 + 150.0 * rng.next();
                Arc::new(h)
            })
            .collect();
        let cache = BubbleCache::default();
        use std::sync::atomic::Ordering::Relaxed;
        let (mut warm_ms, mut total_ms, mut alive) = (0.0f64, 0.0f64, 0usize);
        let (mut b0, mut s0) = (0u64, 0u64);
        let mut state_active = 0usize;
        pool.install(|| {
            for k in 0..=steps {
                let tm = t0 + k as f64;
                let f = [15.0 * k as f64, 0.0];
                let ts = std::time::Instant::now();
                let st = State::build_cached(&setup, all.clone(), tm, &[f], 1.0, k as i64, &cache, true);
                let ms = ts.elapsed().as_secs_f64() * 1e3;
                if k == 0 {
                    warm_ms = ms;
                    b0 = cache.stats.build_ns.load(Relaxed);
                    s0 = cache.stats.source_ns.load(Relaxed);
                } else {
                    total_ms += ms;
                }
                alive = st.bubble_count();
                state_active = st.active.len();
            }
        });
        let sec = steps as f64;
        let build = (cache.stats.build_ns.load(Relaxed) - b0) as f64 / 1e6;
        let src = (cache.stats.source_ns.load(Relaxed) - s0) as f64 / 1e6;
        let (bytes, n_tab) = cache_bytes(&cache);
        // цена опроса: 20000 случайных точек в круге 1500 м вокруг фокуса, высота 10…1400 м, режим шаблона
        let f_end = [15.0 * steps as f64, 0.0];
        let st = State::build_cached(&setup, all.clone(), t0 + sec, &[f_end], 1.0, 99, &cache, true);
        let mut prng = Rng(77);
        let pts: Vec<[f32; 3]> = (0..20000)
            .map(|_| {
                let r = 1500.0 * prng.next().sqrt();
                let a = std::f64::consts::TAU * prng.next();
                [
                    (f_end[0] + r * a.cos()) as f32,
                    (10.0 + 1390.0 * prng.next()) as f32,
                    (r * a.sin()) as f32,
                ]
            })
            .collect();
        let ts = std::time::Instant::now();
        let mut acc = 0.0;
        for p in &pts {
            let (o, uh) = st.sample_bubble(&setup, &NoClouds, *p, t0 + sec);
            acc += o[0] + uh[0];
        }
        let ns_pt = ts.elapsed().as_secs_f64() * 1e9 / pts.len() as f64;
        assert!(acc.is_finite());
        println!(
            "radius_cost: R={radius:.0} термиков {n}, активных {state_active}, таблиц-пузырей {alive}, warm_ms={warm_ms:.0}, \
             build_ms_per_s={:.1} (таблицы {:.1} + источники {:.1}), State::build {:.1} мс/с, кеш {n_tab} таблиц {:.1} МБ, {ns_pt:.0} нс/точку",
            (build + src) / sec,
            build / sec,
            src / sec,
            total_ms / sec,
            bytes as f64 / 1048576.0
        );
        out.push(json!({"kind": "cost", "radius_m": radius, "thermals_total": n, "thermals_active": state_active,
            "bubbles_alive": alive, "warm_ms": warm_ms, "build_ms_per_s": (build + src) / sec,
            "tables_ms_per_s": build / sec, "sources_ms_per_s": src / sec, "state_build_ms_per_s": total_ms / sec,
            "cache_tables": n_tab, "cache_mb": bytes as f64 / 1048576.0, "query_ns_per_point": ns_pt}));
    }
    for o in &out {
        println!("RADJSON {o}");
    }
}

/// Несколько фокусов (боты и пилоты сети — отдельные фокусы, у каждого свой круг): цена сборки для 1 и 4 разнесённых
/// фокусов (±5000 м от центра по осям) при радиусе 1000 и 2000 м, 20 шагов по 1 с. Печатает `RADJSON {"kind":"foci",…}`.
#[test]
#[cfg_attr(
    debug_assertions,
    ignore = "цена меряется в release: cargo test --release … radius_foci"
)]
fn radius_foci() {
    let zl = 1400.0;
    let n_a = 8.5 / (zl * zl);
    let half = 9000.0;
    let t0 = 1000.0;
    let steps = 20usize;
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(1)
        .build()
        .unwrap();
    let mut rng = Rng(2026);
    let n = (n_a * 4.0 * half * half) as usize;
    let all: Vec<Arc<AtmoThermal>> = (0..n)
        .map(|i| {
            let x = (rng.next() * 2.0 - 1.0) * half;
            let z = (rng.next() * 2.0 - 1.0) * half;
            let w0 = 1.5 + 2.5 * rng.next();
            let life = 180.0 + 510.0 + 300.0;
            let mut h = thermal_at(i as i64 + 1, x as f32, z as f32, zl, w0, t0 - rng.next() * life);
            h.t_grow = 120.0 + 120.0 * rng.next();
            h.t_mature = 300.0 + 420.0 * rng.next();
            h.t_decay = 150.0 + 150.0 * rng.next();
            Arc::new(h)
        })
        .collect();
    let base = [[0.0f64, 0.0], [5000.0, 0.0], [-5000.0, 0.0], [0.0, 5000.0]];
    let mut out = Vec::new();
    for &radius in &[1000.0f64, 2000.0] {
        for &nf in &[1usize, 4] {
            let setup = setup_with(radius);
            let cache = BubbleCache::default();
            use std::sync::atomic::Ordering::Relaxed;
            let (mut warm_ms, mut b0, mut s0, mut alive) = (0.0f64, 0u64, 0u64, 0usize);
            pool.install(|| {
                for k in 0..=steps {
                    let foc: Vec<[f64; 2]> =
                        base[..nf].iter().map(|f| [f[0] + 15.0 * k as f64, f[1]]).collect();
                    let ts = std::time::Instant::now();
                    let st = State::build_cached(&setup, all.clone(), t0 + k as f64, &foc, 1.0, k as i64, &cache, true);
                    if k == 0 {
                        warm_ms = ts.elapsed().as_secs_f64() * 1e3;
                        b0 = cache.stats.build_ns.load(Relaxed);
                        s0 = cache.stats.source_ns.load(Relaxed);
                    }
                    alive = st.bubble_count();
                }
            });
            let sec = steps as f64;
            let ms = ((cache.stats.build_ns.load(Relaxed) - b0) + (cache.stats.source_ns.load(Relaxed) - s0)) as f64
                / 1e6
                / sec;
            let (bytes, n_tab) = cache_bytes(&cache);
            println!(
                "radius_foci: R={radius:.0} фокусов {nf}: пузырей {alive}, warm_ms={warm_ms:.0}, build_ms_per_s={ms:.1}, кеш {n_tab} таблиц {:.1} МБ",
                bytes as f64 / 1048576.0
            );
            out.push(json!({"kind": "foci", "radius_m": radius, "foci": nf, "bubbles_alive": alive, "warm_ms": warm_ms,
                "build_ms_per_s": ms, "cache_tables": n_tab, "cache_mb": bytes as f64 / 1048576.0}));
        }
    }
    for o in &out {
        println!("RADJSON {o}");
    }
}
