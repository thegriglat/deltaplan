//! RW-6o: клипмап окон 100/50 м в крейте (`field::clipmap` + `Formula`) — загрузка с окнами,
//! пересчёт на прежних местах, сдвиг за фокусом, стык уровней, подача набором, откат на область,
//! детерминизм по потокам, отмена.
//!
//! Тесты без `--ignored` идут в профиле `dev` (picard_rs с opt-level 2) на малой области синтетики
//! (`domain_l_m` 12 км, грубый критерий `tol_scale` 5, режим притока `inflow`: один проход) и
//! укладываются в ~2 мин: геометрия окон, загрузка с окнами, откат на область, выгрузка посреди
//! окна, поведение RW-6t без окон. Сдвиги, подача, детерминизм, Онгудай, стык уровней и сверка с
//! GPU-дампом окон (`tests/data/window`) — `#[ignore]` (тяжёлое, release):
//! `cargo test --release -p dp-air --test clipmap -- --ignored --nocapture --test-threads=1`.
use dp_air::field::clipmap::{ClipMap, center_of, corner, shift_level, shifted_corner, solve_pair};
use dp_air::field::runtime::{RtCfg, ground_height};
use dp_air::field::weather_core::Cells;
use dp_air::field::wind_profile::CaseProfile;
use dp_air::field::window::{
    AirWindowCase, N_WINDOW, ParentPair, PrevPair, window_level, window_pair_inputs,
};
use dp_air::fixtures::read_place;
use dp_air::{AirModel, Conditions, Configs, Focus, Formula, InflowMode, Place, SampleMode, State};
use dp_air::{NestSrc, ShiftSrc};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
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

/// Малая область синтетики, грубый критерий, детерминированный режим.
fn cheap(v: &mut Value) {
    v["air"]["deterministic"] = json!(true);
    v["air"]["domain_l_m"] = json!(12000.0);
    v["air"]["threads"] = json!(4);
    v["air"]["tol_scale"] = json!(5.0);
    v["air"]["timeout_s"] = json!(900.0);
    v["air_model"]["edge_blend_cells"] = json!(5.0);
}

fn place(name: &str) -> Place {
    read_place(&repo().join(format!("tests/fixtures/wind/places/{name}.json"))).unwrap()
}

/// Условия без подстройки `k`: один проход загрузки.
fn cond_inflow(preset: &str) -> Conditions {
    Conditions::from_json(&format!(
        r#"{{"preset":"{preset}","start_hour":12,"speed":1,"blend_s":null,"rebuild":false,"inflow_mode":"inflow"}}"#
    ))
    .unwrap()
}

fn cond(preset: &str) -> Conditions {
    Conditions::from_json(&format!(
        r#"{{"preset":"{preset}","start_hour":12,"speed":1,"blend_s":null,"rebuild":false}}"#
    ))
    .unwrap()
}

/// Фокус над землёй в точке мира `(x, z)`.
fn focus_at(pl: &Place, x: f32, z: f32) -> Focus {
    Focus {
        pos: [x, ground_height(pl, x, z) + 10.0, z],
        weight: 1.0,
    }
}

/// Ждёт `Ready` и принимает готовую задачу (окна `clip()` обновляются при приёме).
fn wait_ready(m: &mut Formula, limit: f64) {
    let t0 = Instant::now();
    loop {
        let s = m.status();
        match s.state {
            State::Ready => {
                m.poll();
                return;
            }
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

fn sample(m: &dyn AirModel, pts: &[[f32; 3]]) -> Vec<[f32; 4]> {
    let mut out = vec![[0.0f32; 4]; pts.len()];
    m.sample_many(pts, SampleMode::Mean, &mut out);
    out
}

fn bits(v: &[[f32; 4]]) -> Vec<u32> {
    v.iter().flatten().map(|x| x.to_bits()).collect()
}

/// Точки вокруг `(x, z)` над землёй.
fn probes(pl: &Place, x: f32, z: f32) -> Vec<[f32; 3]> {
    let mut v = Vec::new();
    for i in -2..=2 {
        for j in -2..=2 {
            let (px, pz) = (x + 150.0 * i as f32, z + 150.0 * j as f32);
            let g = ground_height(pl, px, pz);
            for a in [30.0, 150.0, 400.0] {
                v.push([px, g + a, pz]);
            }
        }
    }
    v
}

fn speed(s: &[f32; 4]) -> f64 {
    f64::from(s[0]).hypot(f64::from(s[2]))
}

/// Уровни поля в атмосфере: сколько (окна и область).
fn n_levels(m: &Formula) -> usize {
    m.level_count()
}

/// Старт сдвигов: окна 100 м (6,4 км) вокруг него и после ухода на 1,7 км остаются в области
/// (±6 км) вне её полосы края.
const X0: f32 = -1800.0;

fn pilot_xy(f: &Focus) -> [f64; 2] {
    [f64::from(f.pos[0]), -f64::from(f.pos[2])]
}

// ---------------------------------------------------------------- геометрия окон

#[test]
fn corners_are_multiples_of_25_and_shift_is_whole_cells() {
    for dx in [100.0, 50.0] {
        for c in [[0.0, 0.0], [7224.77, -324.69], [-1234.5, 987.6]] {
            let o = corner(c, dx);
            assert_eq!(o[0] % 25.0, 0.0);
            assert_eq!(o[1] % 25.0, 0.0);
            let m = center_of(o, dx);
            assert!((m[0] - c[0]).abs() <= 12.5 + 1e-9 && (m[1] - c[1]).abs() <= 12.5 + 1e-9);
            // сдвиг: целое число клеток окна, центр у фокуса
            let p = [c[0] + 913.0, c[1] - 1200.0];
            let s = shifted_corner(o, dx, p);
            assert!(((s[0] - o[0]) / dx - ((s[0] - o[0]) / dx).round()).abs() < 1e-9);
            assert!(((s[1] - o[1]) / dx - ((s[1] - o[1]) / dx).round()).abs() < 1e-9);
            let m2 = center_of(s, dx);
            assert!((m2[0] - p[0]).abs() <= dx / 2.0 + 1e-9 && (m2[1] - p[1]).abs() <= dx / 2.0);
        }
    }
    // пример из GD: окно 100 м с центром (0, 0): угол −3200
    assert_eq!(corner([0.0, 0.0], 100.0), [-3200.0, -3200.0]);
    assert_eq!(corner([0.0, 0.0], 50.0), [-1600.0, -1600.0]);
}

#[test]
fn shift_level_triggers_at_a_quarter_of_the_side() {
    let dxs = [100.0, 50.0];
    let corners = [corner([0.0, 0.0], 100.0), corner([0.0, 0.0], 50.0)];
    let at = |x: f64, y: f64| shift_level(&corners, &dxs, [x, y], 0.25);
    assert_eq!(at(0.0, 0.0), None);
    assert_eq!(at(799.0, 0.0), None);
    assert_eq!(
        at(801.0, 0.0),
        Some(1),
        "50 m window: 0.25 · 3200 m = 800 m"
    );
    assert_eq!(at(0.0, -801.0), Some(1), "y is checked too");
    assert_eq!(at(1599.0, 0.0), Some(1));
    assert_eq!(
        at(1601.0, 0.0),
        Some(0),
        "100 m window first: 0.25 · 6400 m = 1600 m"
    );
    assert_eq!(at(-1601.0, 1000.0), Some(0));
}

// ---------------------------------------------------------------- (1) загрузка с окнами

#[test]
fn load_with_windows_gives_three_levels_and_finite_field() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let f = focus_at(&pl, 0.0, 0.0);
    let pts = probes(&pl, 0.0, 0.0);
    let t0 = Instant::now();
    let mut m = formula(&cfg, pl, &cond_inflow("medium"), Some(f));
    wait_ready(&mut m, 600.0);
    let r = m.report().unwrap();
    eprintln!(
        "load with windows: {:.1} s, windows {:?}",
        t0.elapsed().as_secs_f64(),
        r.windows
            .iter()
            .map(|w| (w.dx, w.iters, w.warm, w.secs))
            .collect::<Vec<_>>()
    );
    assert!(r.windows_error.is_none(), "{:?}", r.windows_error);
    assert_eq!(r.windows.len(), 2);
    assert_eq!((r.windows[0].dx, r.windows[1].dx), (100.0, 50.0));
    assert!(
        r.windows.iter().all(|w| !w.warm),
        "load: start from the parent"
    );
    assert_eq!(n_levels(&m), 3, "[50, 100, area]");
    let clip = m.clip().unwrap();
    assert!(clip.ready());
    // окна с центром на старте, угол кратен 25 м
    for q in 0..2 {
        let c = clip.center(q);
        assert!(c[0].abs() <= 50.0 && c[1].abs() <= 50.0, "{c:?}");
    }
    let out = sample(&m, &pts);
    assert!(out.iter().flatten().all(|v| v.is_finite()));
    assert!(out.iter().any(|s| speed(s) > 0.5), "wind in the windows");
    assert_eq!(m.status().reason, "");
    // окна меняют поле у старта против области
    let cfg0 = configs_with(|v| {
        cheap(v);
        v["air_model"]["window_levels_m"] = json!([]);
    });
    let pl0 = place("synthetic");
    let mut m0 = formula(
        &cfg0,
        pl0.clone(),
        &cond_inflow("medium"),
        Some(focus_at(&pl0, 0.0, 0.0)),
    );
    wait_ready(&mut m0, 600.0);
    assert_eq!(n_levels(&m0), 1);
    let base = sample(&m0, &pts);
    let d = out
        .iter()
        .zip(&base)
        .map(|(a, b)| (speed(a) - speed(b)).abs())
        .fold(0.0, f64::max);
    eprintln!("windows vs area-only, max |Δ|v| {d:.2} m/s");
    assert!(d > 1e-3, "windows must change the field near the start");
}

// ---------------------------------------------------------------- (2) сдвиг

/// Идёт по прямой на восток 10 м/с, шаг `dt` с; возвращает журнал сдвигов.
fn walk(m: &mut Formula, pl: &Place, x0: f32, z: f32, t_end: f64, dt: f64) -> f64 {
    let mut t = 0.0f64;
    while t < t_end {
        t += dt;
        let x = x0 + 10.0 * t as f32;
        m.set_focuses(&[focus_at(pl, x, z)]).unwrap();
        m.advance_to(t).unwrap();
    }
    t
}

#[test]
#[ignore = "release: cargo test --release -p dp-air --test clipmap -- --ignored --nocapture --test-threads=1"]
fn shift_follows_a_walking_focus_with_periods_80_and_160_s() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let mut m = formula(
        &cfg,
        pl.clone(),
        &cond_inflow("medium"),
        Some(focus_at(&pl, X0, 0.0)),
    );
    wait_ready(&mut m, 600.0);
    assert_eq!(m.shifts().len(), 0);
    let dt = 5.0;
    let t = walk(&mut m, &pl, X0, 0.0, 190.0, dt);
    let log = m.shifts();
    for s in log {
        eprintln!(
            "shift t {:.0}..{:.0} s from level {} corners {:?} windows {:?}",
            s.started_t,
            s.delivered_t,
            s.from_level,
            s.corners,
            s.windows
                .iter()
                .map(|w| (w.dx, w.iters, w.warm))
                .collect::<Vec<_>>()
        );
    }
    assert!(log.len() >= 2, "shifts: {}", log.len());
    // 50 м: уход > 800 м → ≈ 80 с; 100 м: > 1,6 км → ≈ 160 с и тянет 50 м
    assert_eq!(log[0].from_level, 1);
    assert!(
        (log[0].started_t - 80.0).abs() <= dt + 1e-9,
        "{}",
        log[0].started_t
    );
    assert_eq!(log[0].windows.len(), 1);
    assert_eq!(log[0].windows[0].dx, 50.0);
    assert!(
        log[0].windows[0].warm,
        "shift: warm start from the previous window"
    );
    let i100 = log
        .iter()
        .position(|s| s.from_level == 0)
        .expect("shift of 100 m");
    assert!((log[i100].started_t - 160.0).abs() <= 2.0 * dt + 1e-9);
    assert_eq!(log[i100].windows.len(), 2, "100 m pulls the 50 m window");
    // центр окон у фокуса после сдвига
    let clip = m.clip().unwrap();
    let f = pilot_xy(&focus_at(&pl, X0 + 10.0 * t as f32, 0.0));
    for q in 0..2 {
        let c = clip.center(q);
        assert!((c[0] - f[0]).abs() < 1000.0, "{c:?} vs {f:?}");
    }
    assert_eq!(n_levels(&m), 3);
    let pts = probes(&pl, X0 + 10.0 * t as f32, 0.0);
    assert!(sample(&m, &pts).iter().flatten().all(|v| v.is_finite()));
}

#[test]
#[ignore = "release: cargo test --release -p dp-air --test clipmap -- --ignored --nocapture --test-threads=1"]
fn circling_focus_never_shifts() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let mut m = formula(
        &cfg,
        pl.clone(),
        &cond_inflow("medium"),
        Some(focus_at(&pl, 150.0, 0.0)),
    );
    wait_ready(&mut m, 600.0);
    let mut t = 0.0f64;
    while t < 400.0 {
        t += 10.0;
        let a = t / 100.0 * std::f64::consts::TAU;
        let (x, z) = (150.0 * a.cos(), 150.0 * a.sin());
        m.set_focuses(&[focus_at(&pl, x as f32, z as f32)]).unwrap();
        m.advance_to(t).unwrap();
    }
    assert_eq!(
        m.shifts().len(),
        0,
        "a 150 m circle is far inside 0.25 of 3.2 km"
    );
}

#[test]
#[ignore = "release: cargo test --release -p dp-air --test clipmap -- --ignored --nocapture --test-threads=1"]
fn shift_waits_for_the_recompute_and_uses_its_conditions() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let c0 = cond_inflow("medium");
    let mut m = formula(&cfg, pl.clone(), &c0, Some(focus_at(&pl, X0, 0.0)));
    wait_ready(&mut m, 600.0);
    let u0 = m.current().unwrap().u10;
    // смена ветра и уход фокуса за порог в один момент: сначала пересчёт поля, потом сдвиг
    let c1 = cond_inflow("strong");
    m.set_conditions(&c1).unwrap();
    m.set_focuses(&[focus_at(&pl, X0 + 900.0, 0.0)]).unwrap();
    m.advance_to(10.0).unwrap();
    let u1 = m.current().unwrap().u10;
    assert!(
        (u1 - u0).abs() > 0.5,
        "recompute for the new wind: {u0} -> {u1}"
    );
    assert_eq!(m.shifts().len(), 1, "shift after the recompute");
    let clip = m.clip().unwrap();
    assert!(
        (clip.rec.u10 - u1).abs() < 1e-9,
        "windows of the shift: the new wind"
    );
    assert_eq!(m.shifts()[0].from_level, 1);
    assert!(
        m.report().unwrap().windows.iter().all(|w| w.warm),
        "recompute: windows on the old places, warm"
    );
}

// ---------------------------------------------------------------- (4) подача

#[test]
#[ignore = "release: cargo test --release -p dp-air --test clipmap -- --ignored --nocapture --test-threads=1"]
fn recompute_delivers_a_new_set_with_a_monotone_blend() {
    // не детерминированный режим: пересчёт подаёт advance_to после готовности фона
    let cfg = configs_with(|v| {
        cheap(v);
        v["air"]["deterministic"] = json!(false);
    });
    let pl = place("synthetic");
    let f = focus_at(&pl, 0.0, 0.0);
    let mut m = formula(&cfg, pl.clone(), &cond_inflow("medium"), Some(f));
    wait_ready(&mut m, 600.0);
    let probe = [[0.0f32, ground_height(&pl, 0.0, 0.0) + 40.0, 0.0]];
    let before = sample(&m, &probe)[0];
    m.set_conditions(&cond_inflow("strong")).unwrap();
    m.advance_to(1.0).unwrap(); // запуск
    assert!(
        m.wait_job(Duration::from_secs(600)),
        "recompute did not finish"
    );
    let t_tick = Instant::now();
    m.advance_to(2.0).unwrap(); // тик подачи
    let mut ticks = vec![t_tick.elapsed()];
    assert_eq!(n_levels(&m), 3, "the new set is [50, 100, area]");
    let blend = 60.0;
    let mut vals = Vec::new();
    let mut t = 2.0;
    while t < 2.0 + blend + 5.0 {
        let s = sample(&m, &probe)[0];
        assert!(s.iter().all(|v| v.is_finite()));
        vals.push(f64::from(s[0]).hypot(f64::from(s[2])));
        t += 5.0;
        m.advance_to(t).unwrap();
    }
    let after = sample(&m, &probe)[0];
    // подмена монотонна: модуль меняется в одну сторону (допуск на ±1e-4)
    let up = vals.windows(2).all(|w| w[1] >= w[0] - 1e-4);
    let down = vals.windows(2).all(|w| w[1] <= w[0] + 1e-4);
    assert!(up || down, "blend is not monotone: {vals:?}");
    assert!(
        (speed(&after) - speed(&before)).abs() > 1e-3,
        "the new field differs from the old one"
    );
    assert!((vals.last().unwrap() - speed(&after)).abs() < 1e-4);
    // после подмены ещё один тик не меняет ответ
    t += 1.0;
    m.advance_to(t).unwrap();
    assert_eq!(bits(&[after]), bits(&sample(&m, &probe)));
    // ещё две подачи: тик подачи замеряется трижды (при занятых ядрах один замер может уйти в
    // планировщик ОС); требование — лучший из трёх ≤ 0,5 мс на release
    for preset in ["medium", "strong"] {
        m.set_conditions(&cond_inflow(preset)).unwrap();
        t += 1.0;
        m.advance_to(t).unwrap();
        assert!(
            m.wait_job(Duration::from_secs(600)),
            "recompute did not finish"
        );
        t += 1.0;
        let t_tick = Instant::now();
        m.advance_to(t).unwrap();
        ticks.push(t_tick.elapsed());
        assert_eq!(n_levels(&m), 3);
    }
    eprintln!("delivery ticks: {ticks:?}");
    if !cfg!(debug_assertions) {
        let best = ticks.iter().min().unwrap();
        assert!(*best < Duration::from_micros(500), "{ticks:?}");
    }
}

// ---------------------------------------------------------------- (5) отказ окна

#[test]
fn window_failure_falls_back_to_the_area_and_a_later_shift_retries() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let mut m = Formula::new();
    m.configure(&cfg, 1).unwrap();
    m.set_conditions(&cond_inflow("medium")).unwrap();
    m.set_focuses(&[focus_at(&pl, X0, 0.0)]).unwrap();
    m.inject_window_failures(1);
    m.load_place(pl.clone()).unwrap();
    wait_ready(&mut m, 600.0);
    let s = m.status();
    assert_eq!(s.state, State::Ready);
    assert!(s.reason.contains("windows"), "reason: {:?}", s.reason);
    assert_eq!(n_levels(&m), 1, "the area only");
    assert!(!m.clip().unwrap().ready());
    let r = m.report().unwrap();
    assert!(r.windows_error.is_some());
    let pts = probes(&pl, 0.0, 0.0);
    assert!(sample(&m, &pts).iter().flatten().all(|v| v.is_finite()));
    // фокус на месте: сдвига нет; фокус ушёл за порог, пауза прошла — окна считаются заново
    m.advance_to(5.0).unwrap();
    assert_eq!(n_levels(&m), 1, "no shift: the focus is at the centre");
    m.set_focuses(&[focus_at(&pl, X0 + 900.0, 0.0)]).unwrap();
    m.advance_to(30.0).unwrap();
    assert_eq!(n_levels(&m), 3, "the next shift tries the windows again");
    assert_eq!(m.status().reason, "");
    assert!(m.clip().unwrap().ready());
    let c = m.clip().unwrap().center(1);
    assert!(
        (c[0] - (f64::from(X0) + 900.0)).abs() <= 50.0,
        "windows round the focus: {c:?}"
    );
}

#[test]
#[ignore = "release: cargo test --release -p dp-air --test clipmap -- --ignored --nocapture --test-threads=1"]
fn failed_shift_keeps_the_old_levels_and_waits_before_retrying() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let mut m = formula(
        &cfg,
        pl.clone(),
        &cond_inflow("medium"),
        Some(focus_at(&pl, X0, 0.0)),
    );
    wait_ready(&mut m, 600.0);
    let pts = probes(&pl, 0.0, 0.0);
    let before = bits(&sample(&m, &pts));
    m.inject_window_failures(1);
    m.set_focuses(&[focus_at(&pl, X0 + 900.0, 0.0)]).unwrap();
    m.advance_to(1.0).unwrap();
    assert_eq!(m.shifts().len(), 0);
    assert!(
        m.status().reason.contains("windows"),
        "{:?}",
        m.status().reason
    );
    assert_eq!(n_levels(&m), 3, "old levels stay");
    assert_eq!(bits(&sample(&m, &pts)), before);
    // пауза: за 5 с повторной попытки нет
    m.advance_to(6.0).unwrap();
    assert_eq!(m.shifts().len(), 0);
    m.advance_to(20.0).unwrap();
    assert_eq!(m.shifts().len(), 1, "retry after the pause");
    assert_eq!(m.status().reason, "");
}

// ---------------------------------------------------------------- (6) без окон

#[test]
fn empty_window_levels_means_no_windows_and_the_area_only_path() {
    let cfg = configs_with(|v| {
        cheap(v);
        v["air_model"]["window_levels_m"] = json!([]);
    });
    let pl = place("synthetic");
    let f = focus_at(&pl, 0.0, 0.0);
    let mut m = formula(&cfg, pl.clone(), &cond("medium"), Some(f));
    wait_ready(&mut m, 600.0);
    let r = m.report().unwrap();
    assert!(m.clip().is_none());
    assert!(r.windows.is_empty() && r.windows_error.is_none());
    assert_eq!(r.planned, 1, "without windows: one pass");
    assert_eq!(n_levels(&m), 1);
    // фокус уходит далеко — сдвигов нет
    m.set_focuses(&[focus_at(&pl, 3000.0, 0.0)]).unwrap();
    m.advance_to(100.0).unwrap();
    assert_eq!(m.shifts().len(), 0);
    // то же поле, что у области с отключёнными окнами и без фокуса
    let pts = probes(&pl, 0.0, 0.0);
    let a = bits(&sample(&m, &pts));
    let mut m2 = formula(&cfg, pl, &cond("medium"), None);
    wait_ready(&mut m2, 600.0);
    assert_eq!(
        a,
        bits(&sample(&m2, &pts)),
        "same field with or without a focus"
    );
    // побитно как до RW-6o (RW-6t): хеш FNV-1a от выборки, снятый на коммите 90fe2ff; с RW-6v
    // (W11 v9: грубый старт обнуляет стенки и землю, как K_BC) и RW-U4 (W11 v11: θ′ = 0 во всех не-неизвестных клетках) — снят заново на коде v11
    let h = a
        .iter()
        .flat_map(|b| b.to_le_bytes())
        .fold(0xcbf2_9ce4_8422_2325u64, |h, b| {
            (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
        });
    assert_eq!(h, 0xa5ec_66d9_9d17_2394, "behaviour of RW-6t: {h:016x}");
}

// ---------------------------------------------------------------- (7) детерминизм

#[test]
#[ignore = "release: cargo test --release -p dp-air --test clipmap -- --ignored --nocapture --test-threads=1"]
fn deterministic_mode_is_bitwise_equal_on_2_and_4_threads() {
    let run = |threads: u64| {
        let cfg = configs_with(|v| {
            cheap(v);
            v["air"]["threads"] = json!(threads);
        });
        let pl = place("synthetic");
        let mut m = formula(
            &cfg,
            pl.clone(),
            &cond_inflow("medium"),
            Some(focus_at(&pl, X0, 0.0)),
        );
        wait_ready(&mut m, 600.0);
        let mut out = Vec::new();
        let mut t = 0.0f64;
        for _ in 0..22 {
            t += 10.0;
            let x = X0 + 10.0 * t as f32;
            m.set_focuses(&[focus_at(&pl, x, 0.0)]).unwrap();
            m.advance_to(t).unwrap();
            let pts = probes(&pl, x, 0.0);
            out.extend(bits(&sample(&m, &pts)));
        }
        (out, m.shifts().len())
    };
    let (a, na) = run(2);
    let (b, nb) = run(4);
    assert!(na >= 1, "the sequence includes a shift");
    assert_eq!(na, nb);
    assert_eq!(a, b, "sample_many is bitwise equal on 2 and 4 threads");
}

// ---------------------------------------------------------------- (8) отмена

#[test]
fn unload_in_the_middle_of_a_window_returns_within_a_second() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let mut m = formula(
        &cfg,
        pl.clone(),
        &cond_inflow("medium"),
        Some(focus_at(&pl, 0.0, 0.0)),
    );
    // ждём стадию окон (progress ≥ 0.9)
    let t0 = Instant::now();
    loop {
        let s = m.status();
        assert_ne!(s.state, State::Failed, "{}", s.reason);
        if s.progress >= 0.9 || s.state == State::Ready {
            break;
        }
        assert!(t0.elapsed() < Duration::from_secs(600));
        std::thread::sleep(Duration::from_millis(2));
    }
    let t = Instant::now();
    m.unload_place();
    let d = t.elapsed();
    eprintln!("unload in the window stage: {d:?} (state before: windows or just ready)");
    assert!(d < Duration::from_secs(1), "{d:?}");
    // Drop посреди окна — так же
    let m2 = formula(
        &cfg,
        pl.clone(),
        &cond_inflow("medium"),
        Some(focus_at(&pl, 0.0, 0.0)),
    );
    let t0 = Instant::now();
    while m2.status().progress < 0.9 && m2.status().state != State::Ready {
        assert!(t0.elapsed() < Duration::from_secs(600));
        std::thread::sleep(Duration::from_millis(2));
    }
    let t = Instant::now();
    drop(m2);
    assert!(t.elapsed() < Duration::from_secs(1), "{:?}", t.elapsed());
    m.load_place(pl).unwrap(); // повторная загрузка после выгрузки жива
    drop(m);
}

// ---------------------------------------------------------------- GPU-дамп окон (release)

struct Dump {
    meta: Value,
    bin: Vec<u8>,
}

impl Dump {
    fn inputs() -> Dump {
        let d = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/data/window");
        Dump {
            meta: serde_json::from_str(&std::fs::read_to_string(d.join("inputs.json")).unwrap())
                .unwrap(),
            bin: std::fs::read(d.join("inputs.bin")).unwrap(),
        }
    }

    fn gpu() -> Dump {
        let d = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/data/window");
        let packed = std::fs::read(d.join("gpu.bin.zst")).unwrap();
        let meta: Value =
            serde_json::from_str(&std::fs::read_to_string(d.join("gpu.json")).unwrap()).unwrap();
        let bin = zstd::decode_all(&packed[..]).unwrap();
        assert_eq!(bin.len() as u64, meta["raw_bytes"].as_u64().unwrap());
        Dump { meta, bin }
    }

    fn span(&self, k: &str, dtype: &str, size: usize) -> &[u8] {
        let a = &self.meta["arrays"][k];
        assert_eq!(a["dtype"], dtype, "{k}");
        let (o, n) = (
            a["offset"].as_u64().unwrap() as usize,
            a["count"].as_u64().unwrap() as usize,
        );
        &self.bin[o..o + size * n]
    }
    fn f64s(&self, k: &str) -> Vec<f64> {
        self.span(k, "f64", 8)
            .chunks_exact(8)
            .map(|c| f64::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn f32s(&self, k: &str) -> Vec<f32> {
        self.span(k, "f32", 4)
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }
    fn u8s(&self, k: &str) -> Vec<u8> {
        self.span(k, "u8", 1).to_vec()
    }
    fn has(&self, k: &str) -> bool {
        self.meta["arrays"].get(k).is_some()
    }
}

fn num(v: &Value, k: &str) -> f64 {
    v[k].as_f64().unwrap_or_else(|| panic!("no number {k}"))
}

/// Окно (с нагревом) из входа дампа.
fn window_heat(inp: &Dump, w: &Value) -> AirWindowCase {
    use dp_air::field::case_prepare::CaseOpts;
    use dp_air::field::place_input::DomainInput;
    use dp_air::field::weather_core::Domain;
    let tag = w["tag"].as_str().unwrap();
    let dom = Domain {
        x0: num(w, "x0"),
        y0: num(w, "y0"),
        nx: num(w, "nx") as usize,
        ny: num(w, "ny") as usize,
        dx: num(w, "dx"),
    };
    let di = DomainInput {
        dom,
        nz: num(w, "nz") as usize,
        dz: num(w, "dz"),
        z_bot: num(w, "z_bot"),
        hc: inp.f64s(&format!("{tag}_hc")),
        gam: inp.f64s(&format!("{tag}_gam")),
        z_i: num(w, "z_i"),
        z_i_col: inp.f32s(&format!("{tag}_z_i_col")),
        z0_map: inp.f64s(&format!("{tag}_z0_map")),
        cells: Cells {
            fr: Vec::new(),
            m: Vec::new(),
        },
    };
    let wind = CaseProfile {
        sun_elev_deg: 0.0,
        class: 0,
        alpha: num(w, "alpha"),
        z_sat: 0.0,
        max_profile: num(w, "max_profile"),
    };
    let heat = inp.f64s(&format!("{tag}_heat"));
    AirWindowCase::from_input(
        &di,
        &wind,
        num(w, "u10_menu"),
        num(w, "wdir"),
        Some(&heat),
        &CaseOpts {
            k: 1.0,
            inflow_mode: InflowMode::Start,
            heat: true,
        },
    )
    .unwrap()
}

struct ParentDump {
    level: dp_air::Level,
    tc: Vec<u8>,
    f: [Vec<f32>; 5],
}

fn parent_of(g: &Dump, w: &Value, set: &str) -> ParentDump {
    let tag = w["tag"].as_str().unwrap();
    let p = &w["parent"];
    let pg = &p["grid"];
    let d: Vec<usize> = p["dims"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_u64().unwrap() as usize)
        .collect();
    let level = dp_air::Level {
        nx: d[0],
        ny: d[1],
        nz: d[2],
        x0: num(pg, "x0"),
        y0: num(pg, "y0"),
        dx: num(pg, "dx"),
        dz: num(pg, "dz"),
        z_bot: num(pg, "z_bot"),
        halo: 1,
    };
    let f = ["u", "v", "w", "th", "thd"].map(|c| g.f32s(&format!("{tag}_par_{set}_{c}")));
    let tc = g.u8s(&format!("{tag}_par_tc"));
    ParentDump { level, tc, f }
}

fn src_of(p: &ParentDump) -> NestSrc<'_> {
    NestSrc {
        tc: &p.tc,
        u: &p.f[0],
        v: &p.f[1],
        w: &p.f[2],
        th: &p.f[3],
        thd: Some(&p.f[4]),
    }
}

fn box_of(a: &[f32], lv: &dp_air::Level, i0: usize, j0: usize, n: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(n * n * lv.nz);
    for k in 0..lv.nz {
        for j in 0..n {
            let b = (k * lv.ny + j0 + j) * lv.nx + i0;
            out.extend_from_slice(&a[b..b + n]);
        }
    }
    out
}

fn max_diff(got: &[f32], want: &[f32]) -> f64 {
    assert_eq!(got.len(), want.len());
    got.iter()
        .zip(want)
        .map(|(g, w)| (f64::from(*g) - f64::from(*w)).abs())
        .fold(0.0, f64::max)
}

/// Пара окна (`window_pair_inputs` + `solve_pair`, как в `Formula`) против GPU игры: итерации
/// |Δ| ≤ max(20, n/10), поле коробки `u_rel` ≤ 1e-3, θ′ ≤ 0,05 К. Загрузка w100 (40/40), w50
/// (40 mech / 50 heat), сдвиг w100 (30; у GPU-дампа — только heat, mech — вслед за ним). Время
/// на 8 и 2 потоках — в отчёт.
#[test]
#[ignore = "release: cargo test --release -p dp-air --test clipmap -- --ignored --nocapture pair_matches_gpu"]
fn pair_matches_gpu() {
    let inp = Dump::inputs();
    let g = Dump::gpu();
    let configs = configs_with(|v| {
        v["air"]["tol_scale"] = json!(1.0);
        v["air"]["timeout_s"] = json!(900.0);
    });
    let mut report = String::new();
    let cancel = Arc::new(AtomicBool::new(false));
    for w in g.meta["windows"].as_array().unwrap() {
        let tag = w["tag"].as_str().unwrap();
        let wi = inp.meta["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|x| x["tag"] == tag)
            .unwrap();
        let heat = window_heat(&inp, wi);
        let warm = w["warm"].as_bool().unwrap();
        let has_mech = w["sets"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["mode"] == "mech");
        let ph = parent_of(&g, w, "heat");
        let pm = if has_mech {
            parent_of(&g, w, "mech")
        } else {
            parent_of(&g, w, "heat")
        };
        let parent = ParentPair {
            level: &ph.level,
            heat: src_of(&ph),
            mech: src_of(&pm),
        };
        // прошлое окно (сдвиг): состояние heat из дампа GPU; mech в дампе нет — то же
        let old = warm.then(|| {
            let sh = &w["shift"];
            let oa = |c: &str| g.f32s(sh["old"][c].as_str().unwrap());
            let old_w = window_heat(
                &inp,
                inp.meta["windows"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|x| x["tag"] == sh["from"])
                    .unwrap(),
            );
            let level = window_level(&old_w.prepare().unwrap());
            (
                level,
                [oa("u"), oa("v"), oa("w"), oa("th"), oa("thd"), oa("p")],
            )
        });
        let prev = old.as_ref().map(|(level, a)| {
            let s = ShiftSrc {
                u: &a[0],
                v: &a[1],
                w: &a[2],
                th: &a[3],
                thd: &a[4],
                p: &a[5],
            };
            PrevPair {
                level,
                heat: s,
                mech: s,
            }
        });
        for threads in [8usize, 2] {
            let mut cfg = RtCfg::from_configs(&configs).unwrap();
            cfg.threads = threads;
            cfg.max_iters = 400;
            let mut inputs = window_pair_inputs(&heat, &parent, prev.as_ref()).unwrap();
            assert_eq!(inputs.warm, warm, "{tag}");
            let level = inputs.level;
            let t = Instant::now();
            let sol = solve_pair(&cfg, &cancel, &mut inputs).unwrap();
            let secs = t.elapsed().as_secs_f64();
            report += &format!(
                "\n  {tag} {threads} пот.: {secs:.2} с, итерации mech/heat {:?}",
                sol.iters
            );
            if threads != 8 {
                continue;
            }
            for s in w["sets"].as_array().unwrap() {
                let mode = s["mode"].as_str().unwrap();
                let (st, it) = if mode == "heat" {
                    (&sol.heat, sol.iters[1])
                } else {
                    (&sol.mech, sol.iters[0])
                };
                let gpu_it = s["iters"].as_u64().unwrap() as i64;
                assert!(
                    (it as i64 - gpu_it).abs() <= 20.max(gpu_it / 10),
                    "{tag} {mode}: итераций {it} (GPU {gpu_it})"
                );
                let bx = &s["box"];
                let (i0, j0, n) = (
                    bx["i0"].as_u64().unwrap() as usize,
                    bx["j0"].as_u64().unwrap() as usize,
                    bx["n"].as_u64().unwrap() as usize,
                );
                let gb = |c: &str| g.f32s(bx["arrays"][c].as_str().unwrap());
                let rb = |a: &[f32]| box_of(a, &level, i0, j0, n);
                let scale = ["u", "v", "w"]
                    .iter()
                    .flat_map(|c| gb(c))
                    .fold(0.0f32, |m, x| m.max(x.abs())) as f64;
                let du = [(&st.u, "u"), (&st.v, "v"), (&st.w, "w")]
                    .iter()
                    .map(|(a, c)| max_diff(&rb(a), &gb(c)))
                    .fold(0.0, f64::max);
                let dth = max_diff(&rb(&st.th), &gb("th"));
                assert!(du / scale <= 1e-3, "{tag} {mode}: u_rel {:.2e}", du / scale);
                assert!(dth <= 0.05, "{tag} {mode}: θ′ {dth:.3e} К");
                report += &format!(
                    "\n    {mode}: итераций {it} (GPU {gpu_it}), u_rel {:.1e}, θ′ {dth:.1e} К",
                    du / scale
                );
            }
        }
        let _ = Dump::has;
    }
    println!("pair_matches_gpu:{report}");
}

/// Онгудай, условия дампа окон, фокус в центре дампа: загрузка с окнами (tol_scale 1 — паритет с
/// GPU) → Ready, три уровня, итерации окон прохода 1 в допуске GPU-дампа; время загрузки на 8 и
/// 2 потоках — в отчёт.
#[test]
#[ignore = "Онгудай, release: cargo test --release -p dp-air --test clipmap -- --ignored --nocapture ongudai_load"]
fn ongudai_load_with_windows_matches_gpu_iterations() {
    let inp = Dump::inputs();
    let cond = Conditions::from_json(&inp.meta["conditions"].to_string()).unwrap();
    let c = inp.meta["center"].as_array().unwrap();
    let (cx, cy) = (c[0].as_f64().unwrap() as f32, c[1].as_f64().unwrap() as f32);
    let g = Dump::gpu();
    for threads in [8u64, 2] {
        let cfg = configs_with(|v| {
            v["air"]["deterministic"] = json!(true);
            v["air"]["tol_scale"] = json!(1.0);
            v["air"]["threads"] = json!(threads);
            v["air"]["timeout_s"] = json!(900.0);
        });
        let pl = place("ongudai");
        let f = focus_at(&pl, cx, -cy);
        let t0 = Instant::now();
        let mut m = formula(&cfg, pl, &cond, Some(f));
        wait_ready(&mut m, 900.0);
        let secs = t0.elapsed().as_secs_f64();
        let r = m.report().unwrap();
        assert!(r.windows_error.is_none(), "{:?}", r.windows_error);
        assert_eq!(n_levels(&m), 3);
        let w1 = &r.passes[0].windows;
        eprintln!(
            "ongudai load, {threads} threads: {secs:.1} s; pass-1 windows {:?}; passes {}",
            w1.iter()
                .map(|w| (w.dx, w.iters, w.secs))
                .collect::<Vec<_>>(),
            r.passes.len()
        );
        assert_eq!(w1.len(), 2);
        // дамп: w100 40/40, w50 mech 40 / heat 50 (холодный старт, k = 1)
        for (w, tag) in w1.iter().zip(["w100", "w50"]) {
            let gw = g.meta["windows"]
                .as_array()
                .unwrap()
                .iter()
                .find(|x| x["tag"] == tag)
                .unwrap();
            for (it, mode) in [(w.iters[0], "mech"), (w.iters[1], "heat")] {
                let s = gw["sets"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|s| s["mode"] == mode)
                    .unwrap();
                let gi = s["iters"].as_u64().unwrap() as i64;
                assert!(
                    (it as i64 - gi).abs() <= 20.max(gi / 10),
                    "{tag} {mode}: итераций {it} (GPU {gi})"
                );
            }
            assert!(!w.warm);
        }
    }
}

/// Стык уровней (clipmap.md, «Стык уровней»): линия на восток от старта через края окон 50 м
/// (+1,6 км) и 100 м (+3,2 км), высоты 50 и 300 м над землёй. Наибольшее изменение выборки за 50 м
/// в полосе края (5 клеток) не больше такого же внутри мелкого окна плюс 5 % местной скорости.
#[test]
#[ignore = "Онгудай, release: cargo test --release -p dp-air --test clipmap -- --ignored --nocapture seam"]
fn seam_between_levels_has_no_jump() {
    let cfg = configs_with(|v| {
        v["air"]["deterministic"] = json!(true);
        v["air"]["tol_scale"] = json!(5.0);
        v["air"]["timeout_s"] = json!(900.0);
    });
    let pl = place("ongudai");
    let st = pl.header().start_sites[0].clone();
    let f = Focus {
        pos: [st.x as f32, st.h_msl as f32 + 10.0, st.z as f32],
        weight: 1.0,
    };
    let mut m = formula(&cfg, pl.clone(), &cond("medium"), Some(f));
    wait_ready(&mut m, 900.0);
    assert_eq!(n_levels(&m), 3);
    let clip = m.clip().unwrap();
    let c50 = clip.center(1);
    let c100 = clip.center(0);
    let (sx, sz) = (st.x as f32, st.z as f32);
    for agl in [50.0f32, 300.0] {
        // линия: x от старта до +3,6 км шагом 10 м; изменение за 50 м = 5 шагов
        let pts: Vec<[f32; 3]> = (0..=360)
            .map(|i| {
                let x = sx + 10.0 * i as f32;
                [x, ground_height(&pl, x, sz) + agl, sz]
            })
            .collect();
        let v = sample(&m, &pts);
        let sp: Vec<f64> = v.iter().map(speed).collect();
        let jump = |i: usize| (sp[i + 5] - sp[i]).abs();
        let local = |i: usize| sp[i].max(sp[i + 5]);
        // края окон в индексах: край = центр + сторона/2 (по x)
        let edge = |c: [f64; 2], dx: f64| (c[0] + 0.5 * 64.0 * dx - f64::from(sx)) / 10.0;
        let e50 = edge(c50, 50.0).round() as usize;
        let band50 = 5.0 * 50.0 / 10.0; // 5 клеток по 50 м, в шагах по 10 м
        let in_band =
            |e: usize, w: f64, i: usize| (i as f64 + 5.0) > e as f64 - w && (i as f64) < e as f64;
        let inside = |i: usize| (i as f64 + 5.0) < e50 as f64 - band50 - 5.0 && i >= 10;
        let max_in = (0..sp.len() - 5)
            .filter(|&i| inside(i))
            .map(jump)
            .fold(0.0, f64::max);
        let (mut worst_band, mut worst_loc) = (0.0f64, 1.0f64);
        for i in (0..sp.len() - 5).filter(|&i| in_band(e50, band50, i)) {
            if jump(i) > worst_band {
                worst_band = jump(i);
                worst_loc = local(i).max(0.5);
            }
        }
        eprintln!(
            "seam 50→100 at {agl} m: band {worst_band:.3}, inside {max_in:.3}, local {worst_loc:.2}"
        );
        assert!(
            worst_band <= max_in + 0.05 * worst_loc + 1e-9,
            "50→100 m, {agl} m AGL: band {worst_band:.3} > inside {max_in:.3} + 5 % of {worst_loc:.2}"
        );
        // 100 м → область: край окна 100 м
        let e100 = edge(c100, 100.0).round() as usize;
        if e100 + 5 < sp.len() {
            let band100 = 5.0 * 100.0 / 10.0;
            let max_in100 = (0..sp.len() - 5)
                .filter(|&i| (i as f64 + 5.0) < e100 as f64 - band100 - 5.0 && i >= e50 + 10)
                .map(jump)
                .fold(0.0, f64::max);
            let mut wb = 0.0f64;
            let mut wl = 1.0f64;
            for i in (0..sp.len() - 5).filter(|&i| in_band(e100, band100, i)) {
                if jump(i) > wb {
                    wb = jump(i);
                    wl = local(i).max(0.5);
                }
            }
            eprintln!(
                "seam 100→400 at {agl} m: band {wb:.3}, inside {max_in100:.3}, local {wl:.2}"
            );
            assert!(
                wb <= max_in100.max(max_in) + 0.05 * wl + 1e-9,
                "100→400 m, {agl} m AGL"
            );
        }
    }
    let _ = json!({});
    let _: Option<&ClipMap> = None;
}

#[test]
fn window_constants_match_the_game() {
    assert_eq!(N_WINDOW, 64);
}

/// Плоское место (море/равнина, рельефа нет): окна сходятся, а не упираются в предел итераций.
#[test]
#[ignore = "release: cargo test --release -p dp-air --test clipmap -- --ignored --nocapture flat_place"]
fn flat_place_windows_converge() {
    let header = r#"{"version":1,"loc":{"id":"flat","center_lat":43.2,"center_lon":34.0,
"utc_offset_h":2.0,"month":7,"day":15},"grid":{"origin_x":-10000,"origin_z":-10000,"spacing":25,
"width":801,"height":801},"surface_classes":{"grass":1},"start_sites":[]}"#;
    let h = dp_air::PlaceHeader::from_json(header).unwrap();
    let n = h.cells();
    let pl = Place::new(h, vec![100.0; n], vec![0; n], vec![1; n], vec![0.5; n]).unwrap();
    let cfg = configs_with(|v| {
        cheap(v);
        v["air"]["domain_l_m"] = json!(14400.0);
    });
    let f = Focus {
        pos: [0.0, 110.0, 0.0],
        weight: 1.0,
    };
    let t0 = Instant::now();
    let mut m = formula(&cfg, pl, &cond("medium"), Some(f));
    wait_ready(&mut m, 900.0);
    let r = m.report().unwrap();
    for (i, p) in r.passes.iter().enumerate() {
        eprintln!(
            "flat pass {}: area {:?}, windows {:?}, {:?}",
            i + 1,
            p.iters,
            p.windows
                .iter()
                .map(|w| (w.dx, w.iters))
                .collect::<Vec<_>>(),
            p.win_error
        );
    }
    eprintln!("flat load {:.1} s", t0.elapsed().as_secs_f64());
    assert!(r.windows_error.is_none(), "{:?}", r.windows_error);
    for w in &r.passes.last().unwrap().windows {
        assert!(w.iters.iter().all(|&i| i < 3000), "{w:?}");
    }
}
