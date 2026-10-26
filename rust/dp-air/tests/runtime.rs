//! RW-6j: оркестровка поля (`Formula`, `field::runtime`) — загрузка, грубый старт (T4a), проходы
//! `k`, срок пересчёта и подмена (T2), отмена (T8), детерминизм по потокам, константы против GD.
//!
//! Тесты идут в профиле `dev` (picard_rs с opt-level 2, см. rust/Cargo.toml) на уменьшенной
//! области (`domain_l_m` 7,2 км, 18 клеток) с критерием игры (`tol_scale` 5). Онгудай (полная
//! область 38,4 км) и точные числа AP-20 — `#[ignore]`, на release:
//! `cargo test --release -p dp-air --test runtime -- --ignored --nocapture --test-threads=1`.
use dp_air::field::runtime::*;
use dp_air::field::weather_core::{WeatherInputs, hour_at};
use dp_air::fixtures::read_place;
use dp_air::{
    AirModel, Code, Conditions, Configs, Focus, Formula, InflowMode, Place, SampleMode, State,
};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------- вспомогательное

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

/// Конфиги игры; `patch` правит разобранный `atmosphere.json`.
fn configs_with(patch: impl Fn(&mut Value)) -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere.json" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            patch(&mut v);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

/// Малая область, грубый критерий, детерминированный режим — проверки оркестровки на -O0.
fn cheap(v: &mut Value) {
    v["air"]["deterministic"] = json!(true);
    v["air"]["domain_l_m"] = json!(7200.0);
    v["air"]["threads"] = json!(4);
    v["air"]["tol_scale"] = json!(5.0);
    v["air"]["timeout_s"] = json!(600.0);
    v["air_model"]["edge_blend_cells"] = json!(1.0);
}

fn place(name: &str) -> Place {
    read_place(&repo().join(format!("tests/fixtures/wind/places/{name}.json"))).unwrap()
}

fn cond_json(preset: &str, extra: &str) -> Conditions {
    Conditions::from_json(&format!(
        r#"{{"preset":"{preset}","start_hour":12,"speed":1,"blend_s":null,"rebuild":false{extra}}}"#
    ))
    .unwrap()
}

fn cond(preset: &str) -> Conditions {
    cond_json(preset, "")
}

/// Фокус на склоне синтетики, где ветер над стартом при k = 1 быстрее ветра меню (strong, область
/// 7,2 км, tol_scale 5: U 6,7 м/с при u10 5,0): нужен второй проход подбора k.
fn hilltop(pl: &Place, _half: f64) -> Focus {
    Focus {
        pos: [1000.0, ground_height(pl, 1000.0, 1000.0) + 10.0, 1000.0],
        weight: 1.0,
    }
}

fn wait_ready(m: &Formula, limit: f64) {
    let t0 = Instant::now();
    loop {
        let s = m.status();
        match s.state {
            State::Ready => return,
            State::Failed => panic!("Failed: {}", s.reason),
            _ => {}
        }
        assert!(t0.elapsed().as_secs_f64() < limit, "no Ready in {limit} s");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn formula(cfg: &Configs, pl: Place, c: &Conditions, focus: Option<Focus>) -> Formula {
    let mut m = Formula::new();
    m.configure(cfg, 1).unwrap();
    m.set_conditions(c).unwrap();
    if let Some(f) = focus {
        m.set_focuses(&[f]).unwrap();
    }
    m.load_place(pl).unwrap();
    m
}

/// Точки у центра области над землёй.
fn probes(pl: &Place) -> Vec<[f32; 3]> {
    let mut v = Vec::new();
    for i in -2..=2 {
        for j in -2..=2 {
            let (x, z) = (300.0 * i as f32, 300.0 * j as f32);
            let g = ground_height(pl, x, z);
            for a in [30.0, 150.0, 400.0] {
                v.push([x, g + a, z]);
            }
        }
    }
    v
}

fn sample(m: &dyn AirModel, pts: &[[f32; 3]]) -> Vec<[f32; 4]> {
    let mut out = vec![[0.0f32; 4]; pts.len()];
    m.sample_many(pts, SampleMode::Mean, &mut out);
    out
}

fn bits(v: &[[f32; 4]]) -> Vec<u32> {
    v.iter().flatten().map(|x| x.to_bits()).collect()
}

fn maxdiff(a: &[[f32; 4]], b: &[[f32; 4]]) -> f32 {
    a.iter()
        .flatten()
        .zip(b.iter().flatten())
        .map(|(x, y)| (x - y).abs())
        .fold(0.0, f32::max)
}

/// Задача напрямую (без `Formula`): `mutate` правит `RtCfg`.
fn job(
    cfgs: &Configs,
    mutate: impl Fn(&mut RtCfg),
    pl: Place,
    c: &Conditions,
    loading: bool,
    focus: Option<Focus>,
    warm: Option<Arc<Pair>>,
) -> Result<JobOut, JobErr> {
    let mut cfg = RtCfg::from_configs(cfgs).unwrap();
    mutate(&mut cfg);
    let inputs = WeatherInputs::from_conditions(c, cfgs).unwrap();
    let rec = CondRec::new(&inputs, c, hour_at(c, 0.0));
    run_job(JobIn {
        cfg: Arc::new(cfg),
        configs: Arc::new(cfgs.clone()),
        place: Arc::new(pl),
        cond: c.clone(),
        rec,
        loading,
        k_mem: None,
        inflow_k: 1.0,
        focus: focus.map(|f| [f.pos[0], f.pos[2]]),
        warm,
        cancel: Arc::new(AtomicBool::new(false)),
        progress: Arc::new(AtomicU32::new(0)),
    })
}

fn total_iters(r: &PassReport) -> usize {
    r.iters[0] + r.iters[1]
}

// ---------------------------------------------------------------- (1) загрузка

#[test]
fn load_synthetic_reaches_ready_with_finite_field() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut m = formula(&cfg, pl, &cond("strong"), None);
    let s = m.status();
    assert!(matches!(s.state, State::Loading | State::Ready));
    wait_ready(&m, 600.0);
    let s = m.status();
    assert_eq!((s.state, s.progress, s.time_s), (State::Ready, 1.0, 0.0));
    let r = m.report().unwrap();
    let p = &r.passes[0];
    eprintln!(
        "synthetic: coarse {:?}, iters {:?}, start {:?}, secs {:?}",
        p.coarse_iters, p.iters, p.start, p.secs
    );
    assert_eq!(p.start, Start::Coarse);
    assert!(p.coarse_iters.is_some() && p.iters.iter().all(|&n| n > 0));
    let out = sample(&m, &pts);
    assert!(out.iter().flatten().all(|v| v.is_finite()));
    let speed = |o: &[f32; 4]| (o[0] * o[0] + o[2] * o[2]).sqrt();
    let mean = out.iter().map(speed).sum::<f32>() / out.len() as f32;
    assert!(mean > 0.5, "mean wind {mean} m/s near the centre");
    assert!(out.iter().all(|o| o[3] == 0.0), "sigma is 0 until RW-8");
    // FULL = MEAN
    let mut full = vec![[0.0f32; 4]; pts.len()];
    m.sample_many(&pts, SampleMode::Full, &mut full);
    assert_eq!(bits(&full), bits(&out));
    // decompose: слагаемое field, итог побитно как sample_many
    let d = m.decompose(pts[7]);
    assert_eq!(d.names, vec!["field".to_string()]);
    assert_eq!(d.total, out[7]);
    assert_eq!(d.vel.len(), 1);
    assert_eq!(d.sigma, vec![0.0]);
    m.unload_place();
    assert_eq!(m.status().state, State::Empty);
}

#[test]
fn load_without_conditions_is_ready_without_field_then_first_advance_computes() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut m = Formula::new();
    m.configure(&cfg, 1).unwrap();
    m.load_place(pl).unwrap();
    assert_eq!(m.status().state, State::Ready);
    assert_eq!(sample(&m, &pts), vec![[0.0; 4]; pts.len()]);
    m.set_conditions(&cond("medium")).unwrap();
    m.advance_to(1.0).unwrap(); // детерминированный режим: ждёт поле
    assert_eq!(m.status().state, State::Ready);
    assert!(m.report().is_some());
    assert!(sample(&m, &pts).iter().flatten().any(|v| *v != 0.0));
}

#[test]
fn failed_load_answers_zeros_and_recovers() {
    let cfg = configs_with(cheap);
    // место меньше области
    let h = dp_air::PlaceHeader::from_json(
        r#"{"version":1,"loc":{"id":"t","center_lat":50.0,"center_lon":86.0,
"utc_offset_h":7.0,"month":7,"day":1},"grid":{"origin_x":-100,"origin_z":-100,"spacing":50,
"width":5,"height":4},"surface_classes":{"grass":1},"start_sites":[]}"#,
    )
    .unwrap();
    let n = h.cells();
    let tiny = Place::new(h, vec![100.0; n], vec![0; n], vec![1; n], vec![0.5; n]).unwrap();
    let mut m = formula(&cfg, tiny, &cond("medium"), None);
    let t0 = Instant::now();
    while m.status().state == State::Loading {
        assert!(t0.elapsed().as_secs() < 60);
        std::thread::sleep(Duration::from_millis(2));
    }
    let s = m.status();
    assert_eq!(s.state, State::Failed);
    assert!(s.reason.contains("too small"), "reason: {}", s.reason);
    assert_eq!(
        sample(&m, &[[0.0, 100.0, 0.0], [10.0, 50.0, 10.0]]),
        vec![[0.0; 4]; 2]
    );
    m.advance_to(10.0).unwrap(); // Failed не мешает времени и не повторяет попытки
    assert_eq!(m.status().state, State::Failed);
    // не заразен: следующий load_place начинает с нуля
    m.load_place(place("synthetic")).unwrap();
    wait_ready(&m, 600.0);
    assert_eq!(m.status().time_s, 0.0);
    // нет конфигов погоды — Failed с причиной
    let mut m2 = Formula::new();
    m2.configure(&Configs::default(), 1).unwrap();
    m2.set_conditions(&cond("medium")).unwrap();
    m2.load_place(place("synthetic")).unwrap();
    let s = m2.status();
    assert_eq!(s.state, State::Failed);
    assert!(s.reason.contains("missing"), "reason: {}", s.reason);
}

#[test]
#[ignore = "Онгудай, release: cargo test --release -p dp-air --test runtime -- --ignored --nocapture"]
fn ongudai_loads_ready_release() {
    let cfg = configs_with(|v| {
        v["air"]["deterministic"] = json!(true);
        v["air"]["tol_scale"] = json!(5.0);
    });
    for with_focus in [false, true] {
        let pl = place("ongudai");
        let pts = probes(&pl);
        let st = pl.header().start_sites[0].clone();
        let focus = with_focus.then_some(Focus {
            pos: [st.x as f32, st.h_msl as f32 + 10.0, st.z as f32],
            weight: 1.0,
        });
        let t0 = Instant::now();
        let mut m = Formula::new();
        m.configure(&cfg, 1).unwrap();
        m.set_conditions(&cond("strong")).unwrap();
        if let Some(f) = focus {
            m.set_focuses(&[f]).unwrap();
        }
        m.load_place(pl).unwrap();
        wait_ready(&m, 900.0);
        let r = m.report().unwrap();
        eprintln!(
            "ongudai load (focus {with_focus}) {:.1} s, log {:?}",
            t0.elapsed().as_secs_f64(),
            r.log
        );
        for (i, p) in r.passes.iter().enumerate() {
            eprintln!(
                "  pass {}: k {:.3} coarse {:?} iters {:?} start {:?} secs {:?}",
                i + 1,
                p.k,
                p.coarse_iters,
                p.iters,
                p.start,
                p.secs
            );
        }
        let out = sample(&m, &pts);
        assert!(out.iter().flatten().all(|v| v.is_finite()));
        assert!(out.iter().flatten().any(|v| *v != 0.0));
    }
}

#[test]
#[ignore = "Онгудай, release: cargo test --release -p dp-air --test runtime -- --ignored --nocapture"]
fn ongudai_advance_to_latency_release() {
    // игра: детерминизма нет, advance_to на главном потоке не ждёт фон (W3: ≤ 0,5 мс)
    let cfg = configs_with(|v| {
        v["air"]["deterministic"] = json!(false);
        v["air"]["tol_scale"] = json!(5.0);
    });
    let pl = place("ongudai");
    let pts = probes(&pl);
    let mut m = formula(&cfg, pl, &cond("strong"), None);
    wait_ready(&m, 900.0);
    m.advance_to(0.1).unwrap(); // принять загруженное
    let (mut worst, mut worst_deliver) = (Duration::ZERO, Duration::ZERO);
    let t_wall = Instant::now();
    // тик 1/60 с игрового времени; на 900 с срок, подача по готовности фона
    let mut t = 890.0;
    m.advance_to(t).unwrap();
    let mut delivered = false;
    while t_wall.elapsed().as_secs() < 300 {
        t += 1.0 / 60.0;
        let before = m.current().unwrap().hour;
        let a = Instant::now();
        m.advance_to(t).unwrap();
        let d = a.elapsed();
        worst = worst.max(d);
        if m.current().unwrap().hour != before {
            worst_deliver = d;
            delivered = true;
            eprintln!("delivered at t={t:.2}, advance_to took {d:?}");
        }
        if delivered && t > 1000.0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(16));
    }
    assert!(delivered);
    assert!(
        worst_deliver < Duration::from_micros(500),
        "advance_to at delivery took {worst_deliver:?} (W3: <= 0.5 ms)"
    );
    eprintln!("worst advance_to {worst:?}, at delivery {worst_deliver:?}, last t {t:.1}");
    let _ = sample(&m, &pts);
}

// ---------------------------------------------------------------- (2) T4a

#[test]
fn t4a_coarse_start_is_used_and_cold_start_is_available() {
    let base = configs_with(cheap);
    let cold = configs_with(|v| {
        cheap(v);
        v["air_model"]["picard_start"] = json!("cold");
    });
    let c = cond("medium");
    let a = job(&base, |_| {}, place("synthetic"), &c, true, None, None).unwrap();
    let b = job(&cold, |_| {}, place("synthetic"), &c, true, None, None).unwrap();
    let (pa, pb) = (&a.report.passes[0], &b.report.passes[0]);
    eprintln!(
        "coarse: {:?}+{:?} → fine {:?}; cold fine {:?}",
        pa.coarse_iters, pa.start, pa.iters, pb.iters
    );
    assert_eq!(pa.start, Start::Coarse);
    assert_eq!(pb.start, Start::Cold);
    assert!(pb.coarse_iters.is_none());
    assert!(a.report.passes[0].coarse_iters.is_some());
}

#[test]
fn t4a_failed_coarse_starts_from_background_without_error() {
    let cfg = configs_with(cheap);
    let c = cond("medium");
    let o = job(
        &cfg,
        |r| r.faults.coarse = true,
        place("synthetic"),
        &c,
        true,
        None,
        None,
    )
    .expect("a failed coarse step is not an error");
    let p = &o.report.passes[0];
    assert_eq!(p.start, Start::Cold);
    assert!(p.coarse_iters.is_none());
    assert!(
        p.notes.iter().any(|n| n.contains("coarse")),
        "{:?}",
        p.notes
    );
    assert!(o.levels.len() == 1);
}

#[test]
fn t4a_warm_pair_skips_coarse_step() {
    let cfg = configs_with(cheap);
    let c = cond("medium");
    let a = job(&cfg, |_| {}, place("synthetic"), &c, true, None, None).unwrap();
    // пересчёт в полёте: тёплый старт от прошлой пары, грубого шага нет
    let b = job(
        &cfg,
        |_| {},
        place("synthetic"),
        &c,
        false,
        None,
        Some(a.pair.clone()),
    )
    .unwrap();
    let p = &b.report.passes[0];
    assert_eq!(p.start, Start::Warm);
    assert!(p.coarse_iters.is_none());
}

#[test]
#[ignore = "release, тяжёлый: cargo test --release -p dp-air --test runtime -- --ignored --nocapture"]
fn t4a_iterations_ongudai_release() {
    // AP-20 (ориентир, не паритет): грубый старт сокращает итерации тонкой сетки 1140 → 793 на 6
    // случаях GPU (tol 1). Здесь: tol_scale 5, пара mech + heat.
    for preset in ["medium", "strong"] {
        let mk = |start: &str| {
            let start = start.to_string();
            configs_with(move |v| {
                v["air"]["tol_scale"] = json!(5.0);
                v["air_model"]["picard_start"] = json!(start.clone());
            })
        };
        let c = cond(preset);
        let t0 = Instant::now();
        let a = job(
            &mk("coarse"),
            |_| {},
            place("ongudai"),
            &c,
            true,
            None,
            None,
        )
        .unwrap();
        let ta = t0.elapsed().as_secs_f64();
        let t1 = Instant::now();
        let b = job(&mk("cold"), |_| {}, place("ongudai"), &c, true, None, None).unwrap();
        let tb = t1.elapsed().as_secs_f64();
        let (pa, pb) = (&a.report.passes[0], &b.report.passes[0]);
        let coarse_total = pa.coarse_iters.map_or(0, |c| c[0] + c[1]);
        eprintln!(
            "ongudai {preset}: coarse {:?} (1/9 of fine cost ≈ {:.0}) + fine {:?} = {} ({ta:.1} s); \
             cold fine {:?} = {} ({tb:.1} s)",
            pa.coarse_iters,
            coarse_total as f64 / 9.0,
            pa.iters,
            total_iters(pa),
            pb.iters,
            total_iters(pb)
        );
        assert!(
            total_iters(pa) < total_iters(pb),
            "{preset}: coarse start must need fewer fine iterations ({} vs {})",
            total_iters(pa),
            total_iters(pb)
        );
    }
}

// ---------------------------------------------------------------- (3) проходы k

/// Формула `_next_k` по таблице `p` GD (таблица сверена с текстом GD ниже).
fn gd_next_k(k: f64, u: f64, u10: f64, table: &[[f64; 2]]) -> f64 {
    let p = if u10 <= table[0][0] {
        table[0][1]
    } else {
        let mut p = table[table.len() - 1][1];
        for i in 1..table.len() {
            if u10 <= table[i][0] {
                let f = (u10 - table[i - 1][0]) / (table[i][0] - table[i - 1][0]);
                p = table[i - 1][1] + (table[i][1] - table[i - 1][1]) * f;
                break;
            }
        }
        p
    };
    (k * (u10 / u).powf(1.0 / p)).clamp(0.3, 1.0)
}

#[test]
fn k_pass_follows_next_k_formula_and_stops_by_pass_tol() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let focus = hilltop(&pl, 0.0);
    let c = cond("strong");
    let u10 = WeatherInputs::from_conditions(&c, &cfg).unwrap().u10;
    let table = [[3.0, 0.57], [6.0, 0.75], [10.0, 0.90]];
    let o = job(&cfg, |_| {}, pl, &c, true, Some(focus), None).unwrap();
    let r = &o.report;
    eprintln!("u10 {u10:.3}, log {:?}", r.log);
    assert_eq!(r.planned, 2);
    assert_eq!(r.log[0].k, 1.0);
    assert!(
        r.log.len() >= 2,
        "the hill top is faster than the menu wind: pass 2 expected"
    );
    let want = gd_next_k(r.log[0].k, r.log[0].u, u10, &table);
    assert!(
        (r.log[1].k - want).abs() < 1e-12,
        "k₁ {} != k₀·(u10/U)^(1/p) {want}",
        r.log[1].k
    );
    assert!(r.log[1].k < 1.0);
    assert_eq!(o.k, r.log[1].k);
    assert_eq!(r.passes[1].start, Start::Warm, "pass 2 starts from pass 1");
    assert!(r.passes[1].coarse_iters.is_none());
    // проходы сверх второго — только пока |U/u10 − 1| > pass_tol
    let o3 = job(
        &cfg,
        |c| c.max_passes = 4,
        place("synthetic"),
        &c,
        true,
        Some(hilltop(&place("synthetic"), 0.0)),
        None,
    )
    .unwrap();
    let l = &o3.report.log;
    eprintln!("max_passes 4: {l:?}");
    assert!(l.len() >= 2 && l.len() <= 4);
    for q in 2..l.len() {
        assert!(
            (l[q - 1].u / u10 - 1.0).abs() > PASS_TOL,
            "pass {} ran although the residual {} <= pass_tol",
            q + 1,
            (l[q - 1].u / u10 - 1.0).abs()
        );
    }
    let last = l[l.len() - 1];
    let by_tol = (last.u / u10 - 1.0).abs() <= PASS_TOL;
    let by_limit = l.len() == 4;
    let pinned = (next_k(l, u10) - last.k).abs() < 1e-6;
    assert!(by_tol || by_limit || pinned, "stopped for no reason: {l:?}");
}

#[test]
fn inflow_mode_is_a_single_pass_with_k_one() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let focus = hilltop(&pl, 0.0);
    let c = cond_json("strong", r#","inflow_mode":"inflow""#);
    assert_eq!(c.inflow_mode, InflowMode::Inflow);
    let o = job(&cfg, |_| {}, pl, &c, true, Some(focus), None).unwrap();
    assert_eq!(o.report.planned, 1);
    assert_eq!(o.report.passes.len(), 1);
    assert_eq!(o.k, 1.0);
    // нет точки старта — тоже один проход
    let o = job(
        &cfg,
        |_| {},
        place("synthetic"),
        &cond("strong"),
        true,
        None,
        None,
    )
    .unwrap();
    assert_eq!((o.report.planned, o.k), (1, 1.0));
}

#[test]
fn failed_second_pass_serves_the_first_pass_field() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let focus = hilltop(&pl, 0.0);
    let o = job(
        &cfg,
        |c| c.faults.fail_pass = Some(2),
        pl,
        &cond("strong"),
        true,
        Some(focus),
        None,
    )
    .unwrap();
    assert_eq!(o.report.passes.len(), 1);
    assert!(o.report.pass_failed.as_ref().unwrap().contains("pass 2"));
    assert_eq!(o.k, 1.0);
    // пересчёт в полёте с отказом — ошибка (прежнее поле остаётся у Formula)
    let e = job(
        &cfg,
        |c| c.faults.fail_pass = Some(1),
        place("synthetic"),
        &cond("strong"),
        false,
        None,
        None,
    );
    assert!(matches!(e, Err(JobErr::Failed(_))));
}

#[test]
fn next_k_inflow_p_and_recompute_rules() {
    let t = [[3.0, 0.57], [6.0, 0.75], [10.0, 0.90]];
    for u10 in [1.0, 3.0, 4.5, 6.0, 8.0, 10.0, 14.0] {
        let p = inflow_p(u10);
        let want = if u10 <= 3.0 {
            0.57
        } else if u10 <= 6.0 {
            0.57 + (0.75 - 0.57) * (u10 - 3.0) / 3.0
        } else if u10 <= 10.0 {
            0.75 + (0.90 - 0.75) * (u10 - 6.0) / 4.0
        } else {
            0.90
        };
        assert!((p - want).abs() < 1e-12, "p({u10})");
        let log = [PassLog { k: 0.8, u: 5.0 }];
        assert!((next_k(&log, u10) - gd_next_k(0.8, 5.0, u10, &t)).abs() < 1e-12);
    }
    assert_eq!(
        next_k(
            &[PassLog {
                k: 0.8,
                u: f64::NAN
            }],
            5.0
        ),
        1.0
    );
    assert_eq!(next_k(&[PassLog { k: 0.8, u: 0.0 }], 5.0), 1.0);
    // секущая по двум проходам, зажим [0,3; 1]
    let two = [PassLog { k: 1.0, u: 6.0 }, PassLog { k: 0.8, u: 5.0 }];
    let k = next_k(&two, 4.0);
    let sec = 0.8 + (4.0 - 5.0) * (0.8 - 1.0) / (5.0 - 6.0);
    assert!((0.3..=1.0).contains(&k));
    assert!((k - sec).abs() < 1e-12, "secant {k} vs {sec}");
    // срок и допуски
    let rec = |hour: f64, u10: f64, wdir: f64| CondRec {
        hour,
        u10,
        wdir,
        t_max: Some(25.0),
        sky: "clear".into(),
        inflow: InflowMode::Start,
    };
    let have = rec(12.0, 5.0, 270.0);
    assert_eq!(needs_recompute(None, &have, 15.0), Some("нет поля"));
    let chk = |w: &CondRec| needs_recompute(Some(&have), w, 15.0);
    assert_eq!(chk(&rec(12.2, 5.04, 270.9)), None);
    assert_eq!(chk(&rec(12.2, 5.06, 270.0)), Some("смена ветра"));
    assert_eq!(chk(&rec(12.2, 5.0, 271.1)), Some("смена ветра"));
    assert_eq!(chk(&rec(12.2, 5.0, 269.1)), None);
    assert_eq!(chk(&rec(12.25, 5.0, 270.0)), Some("срок"));
    let mut w = rec(12.0, 5.0, 270.0);
    w.t_max = Some(25.3);
    assert_eq!(chk(&w), Some("смена погоды"));
    w.t_max = None;
    assert_eq!(chk(&w), Some("смена погоды"));
    w.t_max = Some(25.2);
    w.sky = "overcast".into();
    assert_eq!(chk(&w), Some("смена погоды"));
    assert_eq!(slot(12.2499, 15.0), 48);
    assert_eq!(slot(12.25, 15.0), 49);
    assert!((slot_hour(12.4, 15.0) - 12.25).abs() < 1e-12);
    // угол через 0°/360°
    let a = rec(12.0, 5.0, 359.5);
    assert_eq!(needs_recompute(Some(&a), &rec(12.0, 5.0, 0.4), 15.0), None);
    assert_eq!(dir_key(359.6), 0);
    assert_eq!(dir_key(-0.4), 0);
}

// ---------------------------------------------------------------- (4) T2: срок и подмена

const HOUR_S: f64 = 3600.0;

#[test]
fn recompute_on_slot_blends_monotonically_and_ends_at_the_new_field() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut m = formula(&cfg, pl, &cond("strong"), None);
    m.advance_to(1.0).unwrap();
    assert_eq!(m.status().state, State::Ready);
    assert_eq!(m.current().unwrap().hour, 12.0);
    let old = sample(&m, &pts);
    // внутри срока (до 900 с) поле не меняется
    m.advance_to(600.0).unwrap();
    assert_eq!(bits(&sample(&m, &pts)), bits(&old));
    assert_eq!(m.current().unwrap().hour, 12.0);
    // срок 12:15 = 900 с: подача в этот момент, подмена за blend_s = 60 с
    m.advance_to(900.0).unwrap();
    assert_eq!(m.current().unwrap().hour, 12.25);
    assert_eq!(m.report().unwrap().passes[0].start, Start::Warm);
    assert_eq!(
        bits(&sample(&m, &pts)),
        bits(&old),
        "blend starts at the slot moment"
    );
    let mut series = vec![sample(&m, &pts)];
    for t in [915.0, 930.0, 945.0, 960.0] {
        m.advance_to(t).unwrap();
        series.push(sample(&m, &pts));
    }
    m.advance_to(1000.0).unwrap();
    let new = sample(&m, &pts);
    assert_eq!(
        bits(series.last().unwrap()),
        bits(&new),
        "t_apply + blend_s: the new field"
    );
    let total = maxdiff(&old, &new);
    eprintln!("slot 12:15: max |Δv| old→new = {total:.4} m/s");
    assert!(total > 0.0, "the fields differ");
    // монотонно по каждой компоненте: old + (new − old)·s(t), s растёт
    let comp = |s: &[[f32; 4]], q: usize| *s.iter().flatten().nth(q).unwrap();
    for q in 0..old.len() * 4 {
        let (o, n) = (comp(&old, q), comp(&new, q));
        let mut prev = o;
        for s in &series {
            let v = comp(s, q);
            if n >= o {
                assert!(v >= prev - 1e-5 && v <= n + 1e-5, "comp {q} not monotone");
            } else {
                assert!(v <= prev + 1e-5 && v >= n - 1e-5, "comp {q} not monotone");
            }
            prev = v;
        }
    }
    // два опроса на одном t равны, тот же t — без изменений
    assert_eq!(bits(&sample(&m, &pts)), bits(&new));
    m.advance_to(1000.0).unwrap();
    assert_eq!(bits(&sample(&m, &pts)), bits(&new));
}

#[test]
fn condition_change_recomputes_from_the_moment_of_change() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut m = formula(&cfg, pl, &cond("medium"), None);
    m.advance_to(10.0).unwrap();
    let old = sample(&m, &pts);
    // ветер меню сменили на t = 100: подмена с этого момента
    m.advance_to(100.0).unwrap();
    m.set_conditions(&cond("strong")).unwrap();
    m.advance_to(100.5).unwrap();
    assert_eq!(m.current().unwrap().u10, 18.0 / 3.6);
    let s0 = sample(&m, &pts);
    assert!(maxdiff(&old, &s0) < 0.2, "blend has just started");
    m.advance_to(161.0).unwrap();
    let s1 = sample(&m, &pts);
    m.advance_to(300.0).unwrap();
    let s2 = sample(&m, &pts);
    assert_eq!(bits(&s1), bits(&s2), "blend finished at t_change + 60 s");
    assert!(maxdiff(&old, &s2) > 0.01);
    // те же условия — пересчёта нет
    let rep = m.report().unwrap().wall_s;
    m.set_conditions(&cond("strong")).unwrap();
    m.advance_to(310.0).unwrap();
    assert_eq!(m.report().unwrap().wall_s, rep);
    // rebuild = true — пересчёт принудительно
    let mut c = cond("strong");
    c.rebuild = true;
    m.set_conditions(&c).unwrap();
    m.advance_to(320.0).unwrap();
    assert_ne!(m.report().unwrap().wall_s, rep);
}

#[test]
fn start_at_jumps_to_the_state_of_that_time() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut m = formula(&cfg, pl, &cond("strong"), None);
    wait_ready(&m, 600.0);
    let a = sample(&m, &pts);
    // тот же срок: Ready сразу, время сдвинулось
    m.start_at(300.0).unwrap();
    assert_eq!(m.status().state, State::Ready);
    assert_eq!(m.status().time_s, 300.0);
    assert_eq!(bits(&sample(&m, &pts)), bits(&a));
    // другой срок: Loading до готовности, подача без подмены
    m.start_at(HOUR_S).unwrap();
    assert_eq!(m.status().time_s, HOUR_S);
    wait_ready(&m, 600.0);
    let b = sample(&m, &pts);
    assert!(maxdiff(&a, &b) > 0.0, "13:00 differs from 12:00");
    m.advance_to(HOUR_S + 1.0).unwrap();
    assert_eq!(m.current().unwrap().hour, 13.0);
    assert_eq!(bits(&sample(&m, &pts)), bits(&b));
    // назад — тоже состояние на момент
    m.start_at(0.0).unwrap();
    wait_ready(&m, 600.0);
    assert_eq!(m.status().time_s, 0.0);
}

#[test]
fn nondeterministic_advance_does_not_wait_for_the_background() {
    let cfg = configs_with(|v| {
        cheap(v);
        v["air"]["deterministic"] = json!(false);
    });
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut m = formula(&cfg, pl, &cond("strong"), None);
    let mut worst = Duration::ZERO;
    let t0 = Instant::now();
    // загрузка идёт в фоне: advance_to не ждёт, опросы нули; время мелким шагом (до срока далеко)
    let mut t = 0.0;
    while m.status().state == State::Loading {
        t += 0.01;
        let a = Instant::now();
        m.advance_to(t).unwrap();
        worst = worst.max(a.elapsed());
        assert!(t0.elapsed().as_secs() < 600);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(t > 0.02, "loading took several ticks");
    assert!(t < 800.0);
    // пересчёт на сроке: подача по готовности
    m.advance_to(901.0).unwrap();
    assert_eq!(
        m.current().unwrap().hour,
        12.0,
        "job started, not delivered yet"
    );
    let mut ticks = 0;
    while m.current().unwrap().hour == 12.0 {
        t = 901.0 + ticks as f64 * 0.1 + 0.1;
        let a = Instant::now();
        m.advance_to(t).unwrap();
        worst = worst.max(a.elapsed());
        ticks += 1;
        assert!(t0.elapsed().as_secs() < 900);
        std::thread::sleep(Duration::from_millis(5));
    }
    eprintln!("worst advance_to {worst:?} over the whole run, ticks {ticks}");
    assert!(
        worst < Duration::from_millis(100),
        "advance_to blocked for {worst:?}"
    );
    assert!(sample(&m, &pts).iter().flatten().any(|v| *v != 0.0));
}

// ---------------------------------------------------------------- (5) T8: отмена

/// Предел возврата отмены: ≤ 1 с на release (проверяют тесты Онгудая `#[ignore]`). На -O0
/// подготовка решения (30 V-циклов фона до первой итерации) в десятки раз медленнее и идёт под
/// нагрузкой параллельных тестов; отмена её не прерывает, а `unload_place`/`Drop` ждут задачу не
/// дольше `JOIN_LIMIT` (5 с) — здесь проверяется только возврат в этот предел и то, что отпущенная
/// задача ничего не подаёт.
fn cancel_limit() -> Duration {
    if cfg!(debug_assertions) {
        Duration::from_secs(8)
    } else {
        Duration::from_secs(1)
    }
}

/// Модель посреди длинного решения (критерий строже: сотни итераций).
fn busy() -> Formula {
    let cfg = configs_with(|v| {
        cheap(v);
        v["air"]["tol_scale"] = json!(0.05);
    });
    let m = formula(&cfg, place("synthetic"), &cond("strong"), None);
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(m.status().state, State::Loading, "must still be solving");
    m
}

#[test]
fn unload_in_the_middle_of_a_solve_returns_within_a_second() {
    let mut m = busy();
    let t = Instant::now();
    m.unload_place();
    let d = t.elapsed();
    eprintln!("unload_place mid-solve: {d:?}");
    assert!(d < cancel_limit(), "{d:?}");
    assert_eq!(m.status().state, State::Empty);
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(m.status().state, State::Empty, "stale job must not publish");
    assert_eq!(sample(&m, &[[0.0, 100.0, 0.0]]), vec![[0.0; 4]]);
}

#[test]
fn drop_in_the_middle_of_a_solve_returns_within_a_second() {
    let m = busy();
    let t = Instant::now();
    drop(m);
    let d = t.elapsed();
    eprintln!("drop mid-solve: {d:?}");
    assert!(d < cancel_limit(), "{d:?}");
}

#[test]
fn changing_the_place_mid_solve_cancels_and_restarts() {
    let mut m = busy();
    let pl = place("synthetic");
    // другой рельеф: вся земля на 60 м выше
    let h2: Vec<f32> = pl.heights().iter().map(|h| h + 60.0).collect();
    let pl2 = Place::new(
        pl.header().clone(),
        h2,
        pl.water().to_vec(),
        pl.cls().to_vec(),
        pl.moist().to_vec(),
    )
    .unwrap();
    let t = Instant::now();
    m.load_place(pl2).unwrap();
    let d = t.elapsed();
    eprintln!("load_place mid-solve: {d:?}");
    assert!(d < cancel_limit(), "{d:?}");
    assert_eq!(m.status().state, State::Loading);
    assert_eq!(m.status().time_s, 0.0);
    // старая задача ничего не подала: поле пустое, пока не посчитано новое
    assert_eq!(sample(&m, &[[0.0, 1000.0, 0.0]]), vec![[0.0; 4]]);
    m.unload_place();
}

#[test]
#[ignore = "Онгудай, release: cargo test --release -p dp-air --test runtime -- --ignored --nocapture"]
fn ongudai_cancel_returns_within_a_second_release() {
    let cfg = configs_with(|v| v["air"]["deterministic"] = json!(true));
    // в разных стадиях: подготовка, грубый шаг, решение тонкой сетки
    for ms in [150u64, 1500, 6000] {
        for how in ["unload", "drop", "reload"] {
            let mut m = formula(&cfg, place("ongudai"), &cond("strong"), None);
            std::thread::sleep(Duration::from_millis(ms));
            let was = m.status().state;
            let t = Instant::now();
            match how {
                "unload" => m.unload_place(),
                "drop" => drop(m),
                _ => {
                    m.load_place(place("synthetic")).unwrap();
                    m.unload_place();
                }
            }
            let d = t.elapsed();
            eprintln!("ongudai {how} after {ms} ms (state {was:?}): {d:?}");
            assert!(
                d < Duration::from_secs(1)
                    + Duration::from_millis(if how == "reload" { 500 } else { 0 }),
                "{how}@{ms}: {d:?}"
            );
        }
    }
}

// ---------------------------------------------------------------- (6) детерминизм по потокам

fn run_sequence(threads: usize) -> Vec<Vec<u32>> {
    let cfg = configs_with(|v| {
        cheap(v);
        v["air"]["threads"] = json!(threads);
    });
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut m = formula(&cfg, pl, &cond("strong"), None);
    let mut out = Vec::new();
    for t in [1.0, 600.0, 900.0, 930.0, 1000.0] {
        m.advance_to(t).unwrap();
        out.push(bits(&sample(&m, &pts)));
    }
    out
}

#[test]
fn same_input_same_field_bitwise_at_2_4_20_threads() {
    let a = run_sequence(2);
    let b = run_sequence(4);
    let c = run_sequence(20);
    assert_eq!(a, b, "2 vs 4 threads");
    assert_eq!(a, c, "2 vs 20 threads");
    assert_ne!(a[0], a[4], "the sequence includes a recompute");
}

// ---------------------------------------------------------------- (7) константы

fn gd(path: &str) -> String {
    std::fs::read_to_string(repo().join(path)).unwrap_or_else(|e| panic!("{path}: {e}"))
}

/// Число после `name` в строке, начинающейся с него (`const X := 0.3`, `x = 2,`).
fn gd_num(text: &str, name: &str) -> f64 {
    let line = text
        .lines()
        .map(str::trim)
        .find(|l| l.starts_with(name))
        .unwrap_or_else(|| panic!("no line starting with '{name}'"));
    let rest = line[name.len()..].trim_start_matches([' ', ':', '=']);
    let end = rest
        .find(|c: char| !(c.is_ascii_digit() || matches!(c, '.' | '-' | 'e' | 'E')))
        .unwrap_or(rest.len());
    rest[..end]
        .parse()
        .unwrap_or_else(|_| panic!("'{name}': cannot parse '{rest}'"))
}

#[test]
fn constants_match_gdscript_and_configs() {
    let rt = gd("scripts/atmosphere/air_model/air_runtime.gd");
    let job = gd("scripts/atmosphere/air_model/air_picard_job.gd");
    let case = gd("scripts/atmosphere/air_model/air_case.gd");
    let prof = gd("scripts/atmosphere/wind_profile.gd");
    assert_eq!(gd_num(&rt, "const DX"), DX);
    assert_eq!(gd_num(&rt, "const INFLOW_K_MIN"), INFLOW_K_MIN);
    assert_eq!(gd_num(&rt, "const INFLOW_K_MAX"), INFLOW_K_MAX);
    assert_eq!(gd_num(&rt, "const START_AGL_M"), START_AGL_M);
    assert_eq!(gd_num(&rt, "const WIND_TOL_MS"), WIND_TOL_MS);
    assert_eq!(gd_num(&rt, "const DIR_TOL_DEG"), DIR_TOL_DEG);
    assert_eq!(gd_num(&rt, "const TMAX_TOL_C"), TMAX_TOL_C);
    assert_eq!(gd_num(&rt, "var max_passes"), MAX_PASSES as f64);
    assert_eq!(gd_num(&rt, "var pass_tol"), PASS_TOL);
    assert_eq!(gd_num(&prof, "const U10_MIN"), U10_MIN);
    // таблица p
    let line = rt
        .lines()
        .find(|l| l.starts_with("const INFLOW_P"))
        .unwrap();
    let nums: Vec<f64> = line
        .split(|c: char| !(c.is_ascii_digit() || c == '.'))
        .filter(|s| s.chars().any(|c| c.is_ascii_digit()))
        .filter_map(|s| s.parse().ok())
        .collect();
    let want: Vec<f64> = INFLOW_P.iter().flatten().copied().collect();
    assert_eq!(nums, want, "INFLOW_P: {line}");
    // решатель: AirPicardJob и AirCase.p
    let sc = dp_air::field::case_build::SolverCfg::new(5.0);
    assert_eq!(gd_num(&job, "var tol_mom"), sc.tol_mom_rms);
    assert_eq!(gd_num(&job, "var tol_th"), sc.tol_th_rms);
    assert_eq!(gd_num(&job, "var tol_div"), sc.tol_div_rms);
    assert_eq!(gd_num(&job, "var check_every"), sc.check_every as f64);
    assert_eq!(gd_num(&job, "var max_outer"), MAX_OUTER as f64);
    assert_eq!(gd_num(&case, "mom_sweeps"), sc.mom_sweeps as f64);
    assert_eq!(gd_num(&case, "heat_sweeps"), sc.heat_sweeps as f64);
    assert_eq!(gd_num(&case, "vcycles"), sc.vcycles as f64);
    assert!(case.contains("local_k = true") && sc.local_k);
    // конфиги: ключи, которые читает оркестровка
    let cfg = RtCfg::from_configs(&configs_with(|_| {})).unwrap();
    let a: Value = serde_json::from_str(&gd("configs/atmosphere.json")).unwrap();
    let n = |p: &str| {
        a.pointer(p)
            .and_then(Value::as_f64)
            .unwrap_or_else(|| panic!("{p}"))
    };
    assert_eq!(cfg.step_min, n("/air_model/recompute_game_min"));
    assert_eq!(cfg.blend_s, n("/air_model/blend_s"));
    assert_eq!(cfg.edge_blend_cells, n("/air_model/edge_blend_cells"));
    assert_eq!(cfg.timeout_s, n("/air/timeout_s"));
    assert_eq!(cfg.timeout_s, 180.0);
    assert_eq!(cfg.limits.max_speed, n("/air_model/max_speed_ms"));
    assert_eq!(cfg.limits.max_w, n("/air_model/max_w_ms"));
    assert_eq!(cfg.omega_after as f64, n("/air_phase/omega/fallback_iters"));
    assert_eq!(cfg.omega as f64, n("/air_phase/omega/fallback_omega"));
    assert_eq!(cfg.late_from as f64, n("/air_phase/nonconv/late_from"));
    assert_eq!(a["air_model"]["picard_start"], "coarse");
    assert_eq!(
        cfg.coarse_factor as f64,
        n("/air_model/picard_coarse_factor")
    );
    assert!(cfg.windows_wanted);
    assert_eq!(cfg.max_iters, MAX_OUTER);
    // новые ключи: игра не детерминирована, потоки — ядра минус одно, tol_scale 5 (решение 24.10)
    assert!(!cfg.deterministic);
    assert_eq!(a["air"]["deterministic"], false);
    assert_eq!(a["air"]["threads"], 0);
    assert_eq!(cfg.threads, resolve_threads(0));
    assert_eq!(cfg.tol_scale, 5.0);
    assert_eq!(cfg.domain_l_m, 38400.0);
}

#[test]
fn threads_zero_is_all_cores_minus_one() {
    let n = std::thread::available_parallelism().map_or(1, |p| p.get());
    assert_eq!(resolve_threads(0), n.saturating_sub(1).max(1));
    assert_eq!(resolve_threads(3), 3);
}

#[test]
fn domain_shrinks_to_the_place_and_refuses_tiny_places() {
    let cfg = RtCfg::from_configs(&configs_with(|_| {})).unwrap();
    let d = domain_for(&place("ongudai"), &cfg).unwrap();
    assert_eq!((d.nx, d.ny, d.dx), (96, 96, 400.0));
    assert_eq!((d.x0, d.y0), (-19200.0, -19200.0));
    let d = domain_for(&place("synthetic"), &cfg).unwrap();
    assert_eq!(d.nx % cfg.coarse_factor, 0);
    assert!(d.nx >= 12 && d.nx < 96);
    let c = coarse_domain(&d, 3);
    assert_eq!((c.dx, c.nx, c.x0), (1200.0, d.nx / 3, d.x0));
    assert!(ground_height(&place("synthetic"), 0.0, 0.0).is_finite());
}

#[test]
fn queries_never_block_on_the_solve_and_survive_garbage() {
    let cfg = configs_with(|v| {
        cheap(v);
        v["air"]["tol_scale"] = json!(0.05);
    });
    let mut m = formula(&cfg, place("synthetic"), &cond("strong"), None);
    let t0 = Instant::now();
    for _ in 0..200 {
        let mut o = [[1.0f32; 4]; 3];
        m.sample_many(
            &[[0.0, 100.0, 0.0], [f32::NAN, 0.0, 0.0], [1e9, 1e9, 1e9]],
            SampleMode::Full,
            &mut o,
        );
        assert!(o.iter().flatten().all(|v| v.is_finite()));
        let _ = m.status();
    }
    assert!(t0.elapsed() < Duration::from_secs(1), "queries blocked");
    assert_eq!(m.status().state, State::Loading);
    assert_eq!(m.advance_to(-1.0).unwrap_err().code, Code::BadInput);
    m.unload_place();
}

#[test]
fn formula_is_send_sync() {
    fn is<T: Send + Sync>() {}
    is::<Formula>();
}

#[test]
fn place_header_carries_climate_and_its_absence_is_allowed() {
    let pl = place("synthetic");
    let c = pl.header().loc.climate.expect("W5 v3: loc.climate");
    assert!(c.has_hh1 && c.has_hh5);
    assert!((c.tx_c - 20.19).abs() < 0.01 && (c.dtr_k - 10.37).abs() < 0.01);
    assert_eq!(c.z_cell_m, 1136.0);
    let h = dp_air::PlaceHeader::from_json(
        r#"{"version":1,"loc":{"id":"t","center_lat":50.0,"center_lon":86.0,"utc_offset_h":7.0,
"month":7,"day":1},"grid":{"origin_x":0,"origin_z":0,"spacing":25,"width":2,"height":2},
"surface_classes":{},"start_sites":[]}"#,
    )
    .unwrap();
    assert!(h.loc.climate.is_none());
}
