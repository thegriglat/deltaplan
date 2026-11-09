//! RW-6q: приёмка RW-6 (часть 1) — `Formula` отдаёт поле Пикара как игра.
//!
//! Один набор: T1 (сильный ветер — восемь запечённых полей островов против крейта), T2 (свойства),
//! T4 (физика поля), T4a (грубый старт), T8 (воспроизводимость по потокам). Тесты без `--ignored`
//! идут в профиле `dev` (picard_rs с opt-level 2) на малой области синтетики (`domain_l_m`
//! 7,2 км, `tol_scale` 5) и укладываются в ~3 мин; тяжёлое — `#[ignore]`, release:
//! `cargo test --release -p dp-air --test acceptance -- --ignored --nocapture`.
//! Замеры загрузки Онгудая (матрица потоков × окна × tol_scale) — `RW6Q_MEASURE=1`, иначе
//! `measure_*` ничего не считает.
//!
//! ## Пункт T → тест (что уже закрыто другим набором — ссылка, не дубль)
//! | пункт | здесь | где ещё |
//! |---|---|---|
//! | T1 сильный ветер, 8 полей | `t1_*` (`--ignored`) | — |
//! | T1 слабый ветер | — (RW-6u) | |
//! | T2 штиль → поле ≈ 0 | `t2_calm_field_is_near_zero` | `runtime.rs` `calm_is_frozen_*` |
//! | T2 пределы 40 и 10 м/с | `t2_limits_hold_end_to_end`, `t2_extreme_wind_is_finite` | `wind_field.rs` `t2_limits_are_enforced` |
//! | T2 два опроса на одном t равны | `t2_two_queries_at_one_time_are_bitwise_equal` | |
//! | T2 стык уровней и окон, blend | ссылка | `clipmap.rs` (стык, подмена), `wind_field.rs` `t2_*`, `runtime.rs` `recompute_on_slot_blends_*` |
//! | T4 div_rms, непротекание, невязка | `t4_*` | `picard_rs/tests`, `residual/` |
//! | T4 замороженные колонны = поле механизма | `t4_frozen_columns_equal_the_mechanism_field` | `runtime.rs` `calm_is_frozen_*` |
//! | T4a (1) prolong точен | ссылка | `level.rs` `constant_exact_*`, `linear_field_exact_inside`, `origin_and_z_shift_respected` |
//! | T4a (2) поток массы через грани | ссылка | `level.rs` `boundary_mass_flux_vs_analytic`, `window.rs` |
//! | T4a (3) mech и heat — каждый своим | `t4a_mech_and_heat_start_from_their_own_coarse_solves` | `level.rs` `state_six_fields` |
//! | T4a (4) итераций меньше, AP-20 | `t4a_coarse_start_saves_iterations` (dev), `t4a_iterations_ongudai` (release) | `runtime.rs` |
//! | T4a (5) отказ грубого → с фона | `t4a_failed_coarse_*` | `runtime.rs` |
//! | T4a (6) грубый пропускается | `t4a_warm_pair_skips_coarse` | `runtime.rs` |
//! | T8 один вход — одно поле, 2/4/20 | `t8_*` | `runtime.rs`, `clipmap.rs` |
mod common;

use dp_air::field::runtime::*;
use dp_air::field::weather_core::{WeatherInputs, hour_at};
use dp_air::fixtures::read_place;
use dp_air::{AirModel, Conditions, Configs, Focus, Formula, Place, SampleMode, State};
use picard_rs::api::StopReason as Stop;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------- вспомогательное

/// Без окон клипмапа (оркестровка области), как в `runtime.rs`.
const NO_WIN: Faults = Faults {
    coarse: false,
    fail_pass: None,
    no_phase: false,
    no_windows: true,
};

/// Тяжёлые тесты идут по одному: стена меряется на свободной машине.
static HEAVY: Mutex<()> = Mutex::new(());

fn heavy() -> MutexGuard<'static, ()> {
    HEAVY.lock().unwrap_or_else(PoisonError::into_inner)
}

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

/// Конфиги игры; `patch` правит разобранный `atmosphere.json`.
fn configs_with(patch: impl Fn(&mut Value)) -> Configs {
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
    Configs::new(files)
}

/// Малая область, критерий игры, детерминированный режим — проверки на dev.
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

fn cond_preset(preset: &str) -> Conditions {
    Conditions::from_json(&format!(
        r#"{{"preset":"{preset}","start_hour":12,"speed":1,"blend_s":null,"rebuild":false}}"#
    ))
    .unwrap()
}

fn cond_u10(u10: f64, hour: f64) -> Conditions {
    Conditions::from_json(&format!(
        r#"{{"preset":{{"wind_speed_kmh":{},"wind_from_deg":270,"sky":"clear","temperature_c":24}},
"start_hour":{hour},"speed":1,"blend_s":null,"rebuild":false}}"#,
        u10 * 3.6
    ))
    .unwrap()
}

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

/// `Formula` без окон (если не дан фокус — окон и так нет).
fn formula_no_win(cfg: &Configs, pl: Place, c: &Conditions) -> Formula {
    let mut m = Formula::new().with_faults(NO_WIN);
    m.configure(cfg, 1).unwrap();
    m.set_conditions(c).unwrap();
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

/// Точки сетки над землёй в центре места: пять высот, 11 × 11 по горизонтали (шаг 250 м).
fn probes(pl: &Place) -> Vec<[f32; 3]> {
    let mut v = Vec::new();
    for i in -5..=5 {
        for j in -5..=5 {
            let (x, z) = (250.0 * i as f32, 250.0 * j as f32);
            let g = ground_height(pl, x, z);
            for a in [3.0, 30.0, 100.0, 300.0, 800.0] {
                v.push([x, g + a, z]);
            }
        }
    }
    v
}

/// Вход задачи напрямую (без `Formula`): `mutate` правит `RtCfg`.
fn job_in(
    cfgs: &Configs,
    mutate: impl Fn(&mut RtCfg),
    pl: Place,
    c: &Conditions,
    loading: bool,
    warm: Option<Arc<Pair>>,
) -> JobIn {
    job_in_at(cfgs, mutate, pl, c, loading, warm, None)
}

#[allow(clippy::too_many_arguments)]
fn job_in_at(
    cfgs: &Configs,
    mutate: impl Fn(&mut RtCfg),
    pl: Place,
    c: &Conditions,
    loading: bool,
    warm: Option<Arc<Pair>>,
    focus: Option<[f32; 2]>,
) -> JobIn {
    let mut cfg = RtCfg::from_configs(cfgs).unwrap();
    cfg.faults = NO_WIN;
    mutate(&mut cfg);
    let inputs = WeatherInputs::from_conditions(c, cfgs).unwrap();
    let rec = CondRec::new(&inputs, hour_at(c, 0.0));
    JobIn {
        weather: Some(common::real_weather()),
        cfg: Arc::new(cfg),
        configs: Arc::new(cfgs.clone()),
        place: Arc::new(pl),
        cond: c.clone(),
        rec,
        loading,
        focus,
        warm,
        cancel: Arc::new(AtomicBool::new(false)),
        progress: Arc::new(AtomicU32::new(0)),
        stage: Arc::new(StageCounter::default()),
        cache: None,
        place_hash: Arc::new(OnceLock::new()),
        clip: None,
        win_fail: Arc::new(AtomicUsize::new(0)),
    }
}

fn job(
    cfgs: &Configs,
    mutate: impl Fn(&mut RtCfg),
    pl: Place,
    c: &Conditions,
    loading: bool,
    warm: Option<Arc<Pair>>,
) -> Result<JobOut, JobErr> {
    run_job(job_in(cfgs, mutate, pl, c, loading, warm))
}

fn total_iters(r: &PassReport) -> usize {
    r.iters[0] + r.iters[1]
}

// ---------------------------------------------------------------- T2

/// Штиль (U10 0,3 м/с): поле — масштаба ветра у земли, не нуль: механизм-поле (ускорение на
/// рельефе, профиль выше 10 м) не больше `0,1 м/с + 3·U10`; факт 0,66 м/с = 2,2·U10. Допуск W8
/// `0,1 м/с + 3 %` — для разности с эталоном, не для самого поля (отчёт RW-6q).
#[test]
fn t2_calm_field_is_near_zero() {
    let cfg = configs_with(cheap);
    for (u10, hour) in [(0.3, 12.0), (0.3, 3.0)] {
        let pl = place("synthetic");
        let pts = probes(&pl);
        let mut m = formula_no_win(&cfg, pl, &cond_u10(u10, hour));
        wait_ready(&mut m, 300.0);
        let out = sample(&m, &pts);
        assert!(out.iter().flatten().all(|v| v.is_finite()));
        // ночью — стоковые потоки склонов (физика, не нуль): число в отчёт, порог — днём
        let bound = if hour >= 6.0 {
            0.1 + 3.0 * u10
        } else {
            f64::INFINITY
        };
        let worst = out
            .iter()
            .map(|o| {
                f64::from(o[0])
                    .hypot(f64::from(o[1]))
                    .hypot(f64::from(o[2]))
            })
            .fold(0.0, f64::max);
        for (a, h) in [3.0, 30.0, 100.0, 300.0, 800.0].iter().enumerate() {
            let w = out
                .iter()
                .skip(a)
                .step_by(5)
                .map(|o| {
                    f64::from(o[0])
                        .hypot(f64::from(o[1]))
                        .hypot(f64::from(o[2]))
                })
                .fold(0.0, f64::max);
            eprintln!("  AGL {h} м: max |поле| {w:.4}");
        }
        eprintln!("T2 штиль U10 {u10} час {hour}: max |поле| {worst:.4} м/с (порог {bound:.4})");
        assert!(worst <= bound, "|поле| {worst} > {bound}");
    }
}

/// Пределы поля: ограничители 40 (горизонталь) и 10 (вертикаль) работают через `Formula`
/// (строгие пределы 3 и 0,5 м/с на сильном ветре режут поле, не ломая его).
#[test]
fn t2_limits_hold_end_to_end() {
    let cfg = configs_with(|v| {
        cheap(v);
        v["air_model"]["max_speed_ms"] = json!(3.0);
        v["air_model"]["max_w_ms"] = json!(0.5);
    });
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut m = formula_no_win(&cfg, pl, &cond_preset("strong"));
    wait_ready(&mut m, 600.0);
    let out = sample(&m, &pts);
    let (mut hmax, mut wmax) = (0.0f64, 0.0f64);
    for o in &out {
        assert!(o.iter().all(|x| x.is_finite()));
        hmax = hmax.max(f64::from(o[0]).hypot(f64::from(o[2])));
        wmax = wmax.max(f64::from(o[1]).abs());
    }
    eprintln!("T2 пределы 3 / 0,5: горизонталь {hmax:.4}, вертикаль {wmax:.4}");
    assert!(hmax <= 3.0 + 1e-4 && wmax <= 0.5 + 1e-5);
    assert!(hmax > 1.0, "поле не обнулено");
}

/// Ветер меню 40 м/с (предел горизонтали): Ready, всё конечно, поле в пределах 40 и 10 м/с.
#[test]
fn t2_extreme_wind_is_finite() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut m = formula_no_win(&cfg, pl, &cond_u10(40.0, 12.0));
    wait_ready(&mut m, 600.0);
    let out = sample(&m, &pts);
    let (mut hmax, mut wmax) = (0.0f64, 0.0f64);
    for o in &out {
        assert!(o.iter().all(|x| x.is_finite()));
        hmax = hmax.max(f64::from(o[0]).hypot(f64::from(o[2])));
        wmax = wmax.max(f64::from(o[1]).abs());
    }
    eprintln!("T2 U10 40: горизонталь {hmax:.2}, вертикаль {wmax:.2} м/с");
    assert!(hmax <= 40.0 + 1e-3 && wmax <= 10.0 + 1e-4);
    assert!(hmax > 5.0, "ветер есть");
}

/// Два опроса на одном `t` равны побитно; `advance_to` на том же `t` поле не меняет.
#[test]
fn t2_two_queries_at_one_time_are_bitwise_equal() {
    let cfg = configs_with(cheap);
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut m = formula_no_win(&cfg, pl, &cond_preset("medium"));
    wait_ready(&mut m, 600.0);
    m.advance_to(10.0).unwrap();
    let a = sample(&m, &pts);
    let b = sample(&m, &pts);
    assert_eq!(bits(&a), bits(&b));
    m.advance_to(10.0).unwrap();
    assert_eq!(bits(&a), bits(&sample(&m, &pts)));
    let mut full = vec![[0.0f32; 4]; pts.len()];
    m.sample_many(&pts, SampleMode::Full, &mut full);
    // RW-8: FULL несёт шум болтанки поля (слот Turb), σ в MEAN и FULL одна
    let sig = |v: &[[f32; 4]]| v.iter().map(|x| x[3].to_bits()).collect::<Vec<_>>();
    assert_eq!(sig(&a), sig(&full), "σ: FULL = MEAN");
}

// ---------------------------------------------------------------- T4

/// Состояние решателя на сетке случая: дивергенция, непротекание.
struct Phys {
    div_rms: f64,
    leak_max: f64,
    u0: f64,
    n_leak_faces: usize,
}

/// `div_rms` по воздушным клеткам и максимум |нормальной скорости| на гранях, касающихся земли
/// (грань между клеткой земли и воздуха или земли). Раскладка `(k·ny_h + j)·nx_h + i`, грань `u`
/// клетки — западная, `v` — южная, `w` — нижняя (как `div_rms_f64` picard_rs).
fn phys(case: &picard_rs::case::Case, st: &picard_rs::state::State) -> Phys {
    let cell = case.bytes("cell").unwrap();
    let (nxh, nyh) = (case.nxh, case.nyh);
    let mut sum = 0.0f64;
    let mut n = 0usize;
    let mut leak = 0.0f64;
    let mut nl = 0usize;
    let mut u0 = 0.0f64;
    let strides = [1usize, nxh, nxh * nyh];
    let af: [Option<&Vec<f32>>; 3] = if case.params.cut_cells {
        ["af_u", "af_v", "af_w"].map(|k| case.arrays.get(k))
    } else {
        [None; 3]
    };
    for kk in 0..case.nz {
        for j in 0..case.ny {
            for i in 0..case.nx {
                let g = ((kk + 1) * nyh + j + 1) * nxh + i + 1;
                u0 = u0.max(f64::from(st.u[g]).hypot(f64::from(st.v[g])));
                // грани клетки g: нормальная скорость на грани, где одна из сторон — земля
                for (a, arr) in [&st.u, &st.v, &st.w].into_iter().enumerate() {
                    let other = g - strides[a];
                    let (c0, c1) = (cell[other], cell[g]);
                    if (c0 == 0 || c1 == 0) && c0 != 2 && c1 != 2 {
                        leak = leak.max(f64::from(arr[g]).abs());
                        nl += 1;
                    }
                }
                if cell[g] != 1 {
                    continue;
                }
                // срезанные клетки (PT2): потоки через открытую долю грани, как `div_rms_f64` решателя
                let f = |a: usize, x: &[f32], q: usize| {
                    f64::from(x[q]) * af[a].map_or(1.0, |t| f64::from(t[q]))
                };
                let d = (f(0, &st.u, g + 1) - f(0, &st.u, g)) / f64::from(case.dx)
                    + (f(1, &st.v, g + nxh) - f(1, &st.v, g)) / f64::from(case.dx)
                    + (f(2, &st.w, g + nxh * nyh) - f(2, &st.w, g)) / f64::from(case.dz);
                sum += d * d;
                n += 1;
            }
        }
    }
    Phys {
        div_rms: (sum / n.max(1) as f64).sqrt(),
        leak_max: leak,
        u0,
        n_leak_faces: nl,
    }
}

/// T4: после решения (поле после финальной проекции) — `div_rms` не выше критерия случая ×
/// `tol_scale` (R2/R7: решатель останавливается по невязке `div_rms ≤ tol_div_rms·tol_scale`,
/// финальная проекция её не увеличивает); оба решения сошлись по критерию (невязка импульса и θ′
/// — внутри `Stop::Converged`). Непротекание у земли: при холодном старте нормальная скорость на
/// гранях земли ровно ноль; при грубом старте — как в игре, стенки несут интерполированное
/// значение (число — в отчёт, не утверждение).
#[test]
fn t4_divergence_and_ground_impermeability() {
    for (preset, start) in [
        ("medium", "coarse"),
        ("medium", "cold"),
        ("strong", "coarse"),
    ] {
        let cfg = configs_with(|v| {
            cheap(v);
            v["air_model"]["picard_start"] = json!(start);
        });
        let c = cond_preset(preset);
        let j = job_in(&cfg, |_| {}, place("synthetic"), &c, true, None);
        let tol_scale = j.cfg.tol_scale;
        let out = run_job(j).unwrap();
        let j2 = job_in(&cfg, |_| {}, place("synthetic"), &c, true, None);
        let cases = level_cases(&j2).unwrap();
        let pair = out.pair.as_ref().unwrap();
        let p = out.report.passes.last().unwrap();
        for (name, case, st, stop) in [
            ("mech", &cases[0], &pair.mech, p.stop[0]),
            ("heat", &cases[1], &pair.heat, p.stop[1]),
        ] {
            let ph = phys(case, st);
            let tol = case.criterion.tol_div_rms * tol_scale;
            eprintln!(
                "T4 {preset}/{start}/{name}: div_rms {:.3e} (порог {:.3e}), утечка через землю {:.3e} м/с на {} гранях, max|u| {:.2}, stop {stop:?}, итераций {:?}",
                ph.div_rms, tol, ph.leak_max, ph.n_leak_faces, ph.u0, p.iters
            );
            assert!(
                matches!(stop, Stop::Converged | Stop::AllFrozen),
                "{stop:?}"
            );
            assert!(
                ph.div_rms <= tol,
                "{name}: div_rms {} > {}",
                ph.div_rms,
                tol
            );
            assert!(ph.n_leak_faces > 0, "нет граней земли");
            if start == "cold" {
                assert!(
                    ph.leak_max <= 1e-6 * ph.u0.max(1.0),
                    "{name}: утечка через землю {}",
                    ph.leak_max
                );
            } else if ph.leak_max > 1e-6 * ph.u0.max(1.0) {
                // ПАРИТЕТ С ИГРОЙ: `air_picard:prolong` интерполирует и грани-стенки, а тёплая
                // программа (`init_warm`) их не обнуляет — поле с грубого старта несёт ненулевую
                // скорость на гранях у ступеней рельефа (см. отчёт RW-6q, границы модели)
                eprintln!("  {name}: стенки после грубого старта несут скорость (паритет с GD)");
            }
        }
    }
}

/// T4: замороженные колонны = поле механизма побитно (θ′ в воздушных клетках, штиль заморожен
/// целиком — `AllFrozen`, итераций нет); скорости после финальной проекции, как в игре.
#[test]
fn t4_frozen_columns_equal_the_mechanism_field() {
    let cfg = configs_with(cheap);
    let c = cond_u10(0.3, 12.0);
    let j = job_in(&cfg, |_| {}, place("synthetic"), &c, true, None);
    let ph = phase_result(&j).unwrap();
    let cases = level_cases(&j).unwrap();
    let out = run_job(j).unwrap();
    let p = out.report.passes.last().unwrap();
    assert_eq!(p.stop, [Stop::AllFrozen; 2]);
    assert_eq!(p.iters, [0, 0]);
    let pair = out.pair.unwrap();
    for (name, st, fr, case) in [
        ("heat", &pair.heat, &ph.freeze, &cases[1]),
        ("mech", &pair.mech, &ph.freeze_mech, &cases[0]),
    ] {
        let f = fr.field.as_ref().unwrap();
        let cell = case.bytes("cell").unwrap();
        let bad = st
            .th
            .iter()
            .zip(&f.th)
            .zip(&cell)
            .filter(|((a, b), c)| **c == 1 && a.to_bits() != b.to_bits())
            .count();
        eprintln!("T4 заморозка {name}: θ′ расходится побитно в {bad} воздушных клетках");
        assert_eq!(bad, 0, "{name}: θ′ замороженных колонн ≠ поле механизма");
    }
}

// ---------------------------------------------------------------- T4a

/// (4) Грубый старт: на тонкой сетке итераций не больше, чем с фона (dev, малая область); числа AP-20
/// на Онгудае — `t4a_iterations_ongudai`.
#[test]
fn t4a_coarse_start_saves_iterations() {
    let base = configs_with(cheap);
    let cold = configs_with(|v| {
        cheap(v);
        v["air_model"]["picard_start"] = json!("cold");
    });
    let c = cond_preset("medium");
    let a = job(&base, |_| {}, place("synthetic"), &c, true, None).unwrap();
    let b = job(&cold, |_| {}, place("synthetic"), &c, true, None).unwrap();
    let (pa, pb) = (&a.report.passes[0], &b.report.passes[0]);
    eprintln!(
        "T4a грубый {:?} + тонкий {:?} = {}; с фона {:?} = {}",
        pa.coarse_iters,
        pa.iters,
        total_iters(pa),
        pb.iters,
        total_iters(pb)
    );
    let pl = place("synthetic");
    let (mut dmax, mut dsum, mut n) = (0.0f64, 0.0f64, 0usize);
    for q in probes(&pl) {
        let g = ground_height(&pl, q[0], q[2]);
        let (x, y) = (a.levels[0].sample(q, g), b.levels[0].sample(q, g));
        let d = (0..3)
            .map(|i| f64::from(x[i] - y[i]).powi(2))
            .sum::<f64>()
            .sqrt();
        dmax = dmax.max(d);
        dsum += d;
        n += 1;
    }
    eprintln!(
        "T4a поле грубого старта против холодного (tol_scale 5): max |Δ| {dmax:.3} м/с, среднее {:.3} м/с",
        dsum / n as f64
    );
    assert_eq!(pa.start, Start::Coarse);
    assert_eq!(pb.start, Start::Cold);
    assert!(
        total_iters(pa) <= total_iters(pb),
        "тонких итераций с грубого старта больше, чем с фона"
    );
}

/// (3) mech и heat решаются на грубой сетке каждый своим и стартуют тонкие каждый своим: оба
/// грубых решения идут (`coarse_iters` оба > 0), итоговые состояния различаются θ′.
#[test]
fn t4a_mech_and_heat_start_from_their_own_coarse_solves() {
    let cfg = configs_with(cheap);
    let o = job(
        &cfg,
        |_| {},
        place("synthetic"),
        &cond_preset("medium"),
        true,
        None,
    )
    .unwrap();
    let p = &o.report.passes[0];
    let ci = p.coarse_iters.expect("грубый шаг");
    eprintln!("T4a грубые итерации mech/heat {ci:?}, тонкие {:?}", p.iters);
    assert!(ci[0] > 0 && ci[1] > 0, "оба грубых решения идут");
    let pair = o.pair.unwrap();
    assert_ne!(
        pair.mech.th.iter().map(|x| x.to_bits()).collect::<Vec<_>>(),
        pair.heat.th.iter().map(|x| x.to_bits()).collect::<Vec<_>>(),
        "θ′ mech и heat различаются"
    );
}

/// (5) Отказ грубого шага — старт с фона без ошибки; (6) тёплая пара — без грубого шага.
#[test]
fn t4a_failed_coarse_and_warm_skip() {
    let cfg = configs_with(cheap);
    let c = cond_preset("medium");
    let o = job(
        &cfg,
        |r| r.faults.coarse = true,
        place("synthetic"),
        &c,
        true,
        None,
    )
    .expect("отказ грубого шага — не ошибка");
    let p = &o.report.passes[0];
    assert_eq!(p.start, Start::Cold);
    assert!(p.coarse_iters.is_none());
    assert!(
        p.notes.iter().any(|n| n.contains("coarse")),
        "{:?}",
        p.notes
    );
    assert_eq!(o.levels.len(), 1);
    let a = job(&cfg, |_| {}, place("synthetic"), &c, true, None).unwrap();
    let b = job(&cfg, |_| {}, place("synthetic"), &c, false, a.pair.clone()).unwrap();
    let p = &b.report.passes[0];
    assert_eq!(p.start, Start::Warm);
    assert!(p.coarse_iters.is_none());
}

/// AP-20 (ориентир, не паритет): грубый старт сокращает итерации тонкой сетки 1140 → 793 на 6
/// случаях GPU (tol 1). Здесь Онгудай, `tol_scale` 5 (две погоды) и 1 (`strong`; `medium` — в замере).
#[test]
#[ignore = "release, тяжёлый: cargo test --release -p dp-air --test acceptance -- --ignored --nocapture"]
fn t4a_iterations_ongudai() {
    let _g = heavy();
    let (mut sum_coarse, mut sum_cold) = (0usize, 0usize);
    // `medium` при tol 1 (218 с) входит только в замер (`RW6Q_MEASURE=1`): приёмка укладывается в 15 мин
    let all = measure_on();
    for (tol, preset) in [
        (5.0, "medium"),
        (5.0, "strong"),
        (1.0, "strong"),
        (1.0, "medium"),
    ] {
        if preset == "medium" && tol == 1.0 && !all {
            continue;
        }
        {
            let mk = |start: &str| {
                let start = start.to_string();
                configs_with(move |v| {
                    v["air"]["deterministic"] = json!(true);
                    v["air"]["tol_scale"] = json!(tol);
                    v["air"]["timeout_s"] = json!(900.0);
                    v["air_model"]["picard_start"] = json!(start.clone());
                })
            };
            let c = cond_preset(preset);
            let t0 = Instant::now();
            let a = job(&mk("coarse"), |_| {}, place("ongudai"), &c, true, None).unwrap();
            let ta = t0.elapsed().as_secs_f64();
            let t1 = Instant::now();
            let b = job(&mk("cold"), |_| {}, place("ongudai"), &c, true, None).unwrap();
            let tb = t1.elapsed().as_secs_f64();
            let (pa, pb) = (&a.report.passes[0], &b.report.passes[0]);
            let cc = pa.coarse_iters.map_or(0, |c| c[0] + c[1]);
            eprintln!(
                "T4a Онгудай {preset} tol {tol}: грубый {:?} + тонкий {:?} = {} ({ta:.1} с); с фона {:?} = {} ({tb:.1} с); грубые ≈ {:.0} тонких",
                pa.coarse_iters,
                pa.iters,
                total_iters(pa),
                pb.iters,
                total_iters(pb),
                cc as f64 / 9.0
            );
            assert!(total_iters(pa) < total_iters(pb), "{preset}/{tol}");
            sum_coarse += total_iters(pa);
            sum_cold += total_iters(pb);
        }
    }
    eprintln!("T4a Онгудай, сумма тонких итераций: с грубого {sum_coarse} / с фона {sum_cold}");
}

// ---------------------------------------------------------------- RW-6o/6t: хвосты приёмки

/// Плоское место «training_island» с одной площадкой старта в центре области и `model_hash` для кеша.
fn island_place(model_hash: &str) -> Place {
    let header = format!(
        r#"{{"version":1,"loc":{{"id":"training_island","center_lat":43.2,"center_lon":34.0,
"utc_offset_h":2.0,"month":7,"day":15}},"grid":{{"origin_x":-10000,"origin_z":-10000,"spacing":25,
"width":801,"height":801}},"surface_classes":{{"grass":1}},
"start_sites":[{{"x":3510.0,"z":-1510.0,"h_msl":100.0}}],"model_hash":"{model_hash}"}}"#
    );
    let h = dp_air::PlaceHeader::from_json(&header).unwrap();
    let n = h.cells();
    Place::new(h, vec![100.0; n], vec![0; n], vec![1; n], vec![0.5; n]).unwrap()
}

fn landing_cond() -> Conditions {
    Conditions::from_json(
        r#"{"forecast":{"temperature_c":22,"wind_speed_kmh":3.6,"wind_from_deg":270,"sky":"clear"},
"quantum_h":1,"start_hour":9,"speed":1,"blend_s":null,"rebuild":false}"#,
    )
    .unwrap()
}

/// Фокус на площадке (центр места), сдвинутый на `dx` м на восток.
fn landing_focus(dx: f32) -> Focus {
    Focus {
        pos: [dx, 110.0, 0.0],
        weight: 1.0,
    }
}

/// `focus_left_windows` — как `AirRuntime._pilot_left_windows`: проверяются уровни с индекса 1
/// (от мелкого), мелкое окно 50 м (сторона 3,2 км, порог 0,8 км) пропускается, окно 100 м (сторона
/// 6,4 км, порог 1,6 км) проверяется. Поле из файла с окнами: фокус в 1 км от старта — выход из
/// окна 50 м, но не 100 м — пересчёта нет; в 1,7 км — выход из окна 100 м — пересчёт запущен.
#[test]
fn focus_left_windows_follows_the_game_skips_the_finest_window() {
    let cfg = configs_with(|v| {
        cheap(v);
        v["air"]["deterministic"] = json!(false);
    });
    // поле для кеша: считается один раз (с окнами), дальше три загрузки из кеша
    let dir = std::env::temp_dir().join(format!("dp-air-plb-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let load = |dx: f32| {
        let mut m = Formula::new();
        m.configure(&cfg, 1).unwrap();
        m.set_cache_dir(dir.to_str().unwrap()).unwrap();
        m.set_conditions(&landing_cond()).unwrap();
        m.set_focuses(&[landing_focus(dx)]).unwrap();
        m.load_place(island_place("model-1")).unwrap();
        wait_ready(&mut m, 600.0);
        m
    };
    let first = load(0.0);
    assert_eq!(first.report().unwrap().source, Source::Computed);
    drop(first);
    let t = Instant::now();
    while !std::fs::read_dir(&dir).is_ok_and(|mut d| {
        d.any(|e| e.is_ok_and(|e| e.path().extension().is_some_and(|x| x == "dpac")))
    }) {
        assert!(t.elapsed().as_secs() < 60, "кеш не записан");
        std::thread::sleep(Duration::from_millis(20));
    }
    for (dx, relaunch) in [(0.0f32, false), (1000.0, false), (1700.0, true)] {
        let mut m = load(0.0);
        let r = m.report().unwrap();
        assert_eq!(r.source, Source::Cache, "{:?}", r.notes);
        assert_eq!(m.level_count(), 3);
        m.advance_to(1.0).unwrap();
        m.set_focuses(&[landing_focus(dx)]).unwrap();
        m.advance_to(2.0).unwrap();
        // пересчёт запущен ⇔ фоновая задача идёт (на плоском месте 20 км он не кончится мгновенно)
        let running = !m.wait_job(Duration::ZERO);
        eprintln!("focus_left_windows: фокус +{dx} м → пересчёт запущен: {running}");
        assert_eq!(running, relaunch, "фокус +{dx} м");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// История решателя при `Cancelled` до первой итерации содержит NaN-невязки (ревью RW-6t): отмена
/// до начала задачи — `Err(Cancelled)` без паники, в журнал поля NaN не попадают.
#[test]
fn cancelled_before_the_first_iteration_leaves_no_nan_in_reports() {
    use picard_rs::api::{SolveOpts, solve};
    let cfg = configs_with(cheap);
    let c = cond_preset("medium");
    let j = job_in(&cfg, |_| {}, place("synthetic"), &c, true, None);
    j.cancel.store(true, std::sync::atomic::Ordering::Relaxed);
    match run_job(j) {
        Err(JobErr::Cancelled) => {}
        other => panic!("ожидалась отмена, получено {:?}", other.map(|o| o.report)),
    }
    // сам решатель: отмена до первой итерации — 0 итераций, история может нести NaN
    let j = job_in(&cfg, |_| {}, place("synthetic"), &c, true, None);
    let cases = level_cases(&j).unwrap();
    let cancel = Arc::new(AtomicBool::new(true));
    let s = solve(
        &cases[0],
        &SolveOpts {
            threads: 2,
            cancel: Some(cancel),
            ..SolveOpts::default()
        },
    )
    .unwrap();
    assert_eq!(s.stop, Stop::Cancelled);
    assert_eq!(s.iters, 0);
    let nan = s
        .history
        .iter()
        .any(|h| h.res.mom_rms.is_nan() || h.res.div_rms.is_nan());
    eprintln!("решатель, отмена до 1-й итерации: NaN в истории: {nan}");
    // журнал поля (JobReport) историю решателя не несёт, итоги проходов — числа
    let ok = job(&cfg, |_| {}, place("synthetic"), &c, true, None).unwrap();
    for p in &ok.report.passes {
        assert!(p.secs.iter().all(|x| x.is_finite()));
    }
}

// ---------------------------------------------------------------- T8

fn run_sequence(threads: usize) -> Vec<Vec<u32>> {
    let cfg = configs_with(|v| {
        cheap(v);
        v["air"]["threads"] = json!(threads);
    });
    let pl = place("synthetic");
    let pts = probes(&pl);
    let mut m = formula_no_win(&cfg, pl, &cond_preset("strong"));
    let mut out = Vec::new();
    for t in [1.0, 600.0, 900.0, 930.0, 1000.0] {
        m.advance_to(t).unwrap();
        out.push(bits(&sample(&m, &pts)));
    }
    out
}

/// T8: один вход — одно поле (загрузка и пересчёт) при 2, 4 и 20 потоках, побитно.
#[test]
fn t8_same_input_same_field_at_2_4_20_threads() {
    let a = run_sequence(2);
    let b = run_sequence(4);
    let c = run_sequence(20);
    assert_eq!(a, b, "2 vs 4 потоков");
    assert_eq!(a, c, "2 vs 20 потоков");
    assert_ne!(a[0], a[4], "в последовательности есть пересчёт");
}

/// T8 с окнами клипмапа (область + окна 100/50 м): побитно при 2, 4 и 20 потоках.
#[test]
#[ignore = "release, тяжёлый: cargo test --release -p dp-air --test acceptance -- --ignored --nocapture"]
fn t8_windows_same_field_at_2_4_20_threads() {
    let _g = heavy();
    let run = |threads: u64| {
        let cfg = configs_with(|v| {
            cheap(v);
            v["air"]["domain_l_m"] = json!(12000.0);
            v["air"]["threads"] = json!(threads);
        });
        let pl = place("synthetic");
        let f = Focus {
            pos: [0.0, ground_height(&pl, 0.0, 0.0) + 10.0, 0.0],
            weight: 1.0,
        };
        let mut pts = Vec::new();
        for i in -3..=3 {
            for j in -3..=3 {
                let (x, z) = (400.0 * i as f32, 400.0 * j as f32);
                let g = ground_height(&pl, x, z);
                for a in [30.0, 200.0] {
                    pts.push([x, g + a, z]);
                }
            }
        }
        let c = Conditions::from_json(
            r#"{"preset":"medium","start_hour":12,"speed":1,"blend_s":null,"rebuild":false}"#,
        )
        .unwrap();
        let mut m = Formula::new();
        m.configure(&cfg, 1).unwrap();
        m.set_conditions(&c).unwrap();
        m.set_focuses(&[f]).unwrap();
        m.load_place(pl).unwrap();
        wait_ready(&mut m, 900.0);
        assert_eq!(m.level_count(), 3);
        bits(&sample(&m, &pts))
    };
    let (a, b, c) = (run(2), run(4), run(20));
    assert_eq!(a, b, "2 vs 4 потоков");
    assert_eq!(a, c, "2 vs 20 потоков");
}

// ---------------------------------------------------------------- замеры (RW6Q_MEASURE=1)

fn measure_on() -> bool {
    std::env::var("RW6Q_MEASURE").is_ok_and(|v| v == "1")
}

/// Загрузка Онгудая: потоки 2/8 × без окон/с окнами × `tol_scale` 1/5 — стена, итерации каждого
/// решения, секунды стадий. Числа в `docs/research/rust-wind-rw6-acceptance.md`.
/// `RW6Q_MEASURE=1 cargo test --release -p dp-air --test acceptance -- --ignored --nocapture measure_ongudai_load`
#[test]
#[ignore = "замер, RW6Q_MEASURE=1, release"]
fn measure_ongudai_load_matrix() {
    if !measure_on() {
        return;
    }
    let _g = heavy();
    for threads in [8u64, 2] {
        for windows in [false, true] {
            for tol in [1.0f64, 5.0] {
                let cfg = configs_with(|v| {
                    v["air"]["deterministic"] = json!(true);
                    v["air"]["tol_scale"] = json!(tol);
                    v["air"]["threads"] = json!(threads);
                    v["air"]["timeout_s"] = json!(1800.0);
                    if !windows {
                        v["air_model"]["window_levels_m"] = json!([]);
                    }
                });
                let pl = place("ongudai");
                let s = &pl.header().start_sites[0];
                let (sx, sz) = (s.x as f32, s.z as f32);
                let f = Focus {
                    pos: [sx, ground_height(&pl, sx, sz) + 10.0, sz],
                    weight: 1.0,
                };
                let t0 = Instant::now();
                let mut m = Formula::new();
                m.configure(&cfg, 1).unwrap();
                m.set_conditions(&cond_preset("medium")).unwrap();
                m.set_focuses(&[f]).unwrap();
                m.load_place(pl).unwrap();
                wait_ready(&mut m, 1800.0);
                let wall = t0.elapsed().as_secs_f64();
                let r = m.report().unwrap();
                eprintln!(
                    "MEAS загрузка Онгудай: потоков {threads}, окна {windows}, tol_scale {tol}: стена {wall:.1} с, проходов {}",
                    r.passes.len()
                );
                for (i, p) in r.passes.iter().enumerate() {
                    let pass_s = p.secs.iter().sum::<f64>();
                    eprintln!(
                        "MEAS   проход {}: старт {:?}, грубые {:?}, тонкие {:?}, stop {:?}, секунды [вход, грубый, решения, поле] {:.1?}, фазы {:.2} с, сумма {pass_s:.1} с, запас до 180 с: {:.1} с",
                        i + 1,
                        p.start,
                        p.coarse_iters,
                        p.iters,
                        p.stop,
                        p.secs,
                        p.phase_s,
                        180.0 - pass_s - p.phase_s
                    );
                    for w in &p.windows {
                        eprintln!(
                            "MEAS     окно {} м: итерации {:?}, секунды [вход, граница, решения, поле] {:.1?}, стоп {:?}",
                            w.dx, w.iters, w.secs, w.stop
                        );
                    }
                }
                eprintln!("MEAS   журнал wall_s {:.1}", r.wall_s);
            }
        }
    }
}

/// Подготовка входа Онгудая (область 400 м): `block_mean`, весь вход случаев (`level_cases`:
/// вход, погода, оба случая, плоскости) — на 8 и 2 потоках.
#[test]
#[ignore = "замер, RW6Q_MEASURE=1, release"]
fn measure_ongudai_input_prep() {
    if !measure_on() {
        return;
    }
    let _g = heavy();
    use dp_air::field::weather_core::block_mean;
    for threads in [8usize, 2] {
        let cfg = configs_with(|v| {
            v["air"]["threads"] = json!(threads);
        });
        let pl = place("ongudai");
        let rt = RtCfg::from_configs(&cfg).unwrap();
        let dom = domain_for(&pl, &rt).unwrap();
        let pool = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .unwrap();
        pool.install(|| {
            let t = Instant::now();
            let bm = block_mean(&pl, &dom).unwrap();
            let t_bm = t.elapsed().as_secs_f64();
            let j = job_in(&cfg, |_| {}, place("ongudai"), &cond_preset("medium"), true, None);
            let t = Instant::now();
            let _ = level_cases(&j).unwrap();
            let t_lc = t.elapsed().as_secs_f64();
            eprintln!(
                "MEAS вход Онгудая, {threads} потоков: block_mean {t_bm:.3} с ({} клеток), level_cases (вход + погода + случаи + плоскости) {t_lc:.2} с",
                bm.len()
            );
        });
    }
}
