//! PT-10 (PT7 v2): потребители поля у земли при срезанных клетках. (а) `k1` поля — первая
//! клетка `cell == 1` (400 м и окна); (б) поле → файл → поле: `k1` побитно, файл без массива
//! (версия 1) читается; (в) выборка у земли без скачков и NaN (печать `max_jump_mps`, `nan`;
//! земля лог-профиля — `hc` (вариант A); вариант B — низ открытой части первой клетки по долям —
//! измерен и отвергнут: скачок 6,47 против 2,22 м/с); (г) фазы: доля нулевых воздушных клеток
//! замороженных колонн (`frozen_zero_frac`); (д) `u*` и `desc` до/после (печать).
//! Тяжёлые: `cargo test --release -p dp-air --test cut_consumers -- --include-ignored --nocapture`.
mod common;

use dp_air::field::cut_input::cut_level;
use dp_air::field::runtime::*;
use dp_air::field::solved::{SolvedField, encode_solved, parse_solved};
use dp_air::field::weather_core::{Domain, WeatherInputs, hour_at};
use dp_air::field::wind_field::{Field, FieldMeta, Limits, Z0};
use dp_air::fixtures::read_place;
use dp_air::{Conditions, Configs, Focus, Place};
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32};
use std::sync::{Arc, OnceLock};

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

fn configs() -> Configs {
    let mut files = Vec::new();
    collect(&repo().join("configs"), "", &mut files);
    for (n, t) in &mut files {
        if n == "atmosphere" {
            let mut v: Value = serde_json::from_str(t).unwrap();
            v["air"]["deterministic"] = json!(true);
            v["air"]["tol_scale"] = json!(5.0);
            *t = serde_json::to_string(&v).unwrap();
        }
    }
    files.sort();
    Configs::new(files)
}

fn place() -> Place {
    read_place(&repo().join("tests/fixtures/wind/places/ongudai.json")).unwrap()
}

fn cond(preset: &str, hour: u32) -> Conditions {
    Conditions::from_json(&format!(
        r#"{{"preset":"{preset}","start_hour":{hour},"speed":1,"blend_s":null,"rebuild":false}}"#
    ))
    .unwrap()
}

fn job_in(windows: bool) -> JobIn {
    job_with(windows, "strong", 12)
}

fn job_with(windows: bool, preset: &str, hour: u32) -> JobIn {
    let cfgs = configs();
    let c = cond(preset, hour);
    let mut cfg = RtCfg::from_configs(&cfgs).unwrap();
    cfg.faults = Faults {
        coarse: false,
        fail_pass: None,
        no_phase: false,
        no_windows: !windows,
    };
    let inputs = WeatherInputs::from_conditions(&c, &cfgs).unwrap();
    let rec = CondRec::new(&inputs, hour_at(&c, 0.0));
    let pl = place();
    let st = pl.header().start_sites[0].clone();
    let focus = Focus {
        pos: [st.x as f32, st.h_msl as f32 + 10.0, st.z as f32],
        weight: 1.0,
    };
    JobIn {
        weather: Some(common::real_weather()),
        cfg: Arc::new(cfg),
        configs: Arc::new(cfgs),
        place: Arc::new(pl),
        cond: c,
        rec,
        loading: true,
        focus: Some([focus.pos[0], focus.pos[2]]),
        warm: None,
        cancel: Arc::new(AtomicBool::new(false)),
        progress: Arc::new(AtomicU32::new(0)),
        stage: Arc::new(StageCounter::default()),
        cache: None,
        place_hash: Arc::new(OnceLock::new()),
        clip: None,
        win_fail: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
    }
}

/// Общее для проверок: поле области 400 м без окон и случай нагрева (типы, доли).
struct Fix {
    field: Arc<Field>,
    cell: Vec<f32>,
    halo: (usize, usize, usize),
}

fn fix() -> &'static Fix {
    static F: OnceLock<Fix> = OnceLock::new();
    F.get_or_init(|| {
        let [_, ch] = level_cases(&job_in(false)).unwrap();
        let out = run_job(job_in(false)).unwrap();
        assert_eq!(out.levels.len(), 1);
        Fix {
            field: out.levels[0].clone(),
            cell: ch.arrays["cell"].clone(),
            halo: (ch.nxh, ch.nyh, ch.nzh),
        }
    })
}

/// Первая воздушная клетка (`cell == 1`, внутренний индекс) каждого столбца; `nz` — нет.
fn k1_of_cells(cell: &[f32], halo: (usize, usize, usize), nx: usize, ny: usize, nz: usize) -> Vec<u32> {
    let (hx, hy, _) = halo;
    (0..nx * ny)
        .map(|c| {
            let (j, i) = (c / nx, c % nx);
            (0..nz)
                .find(|&k| cell[((k + 1) * hy + j + 1) * hx + i + 1] == 1.0)
                .unwrap_or(nz) as u32
        })
        .collect()
}

// ---------------------------------------------------------------- (а) k1 из типов

#[test]
#[ignore = "Онгудай, release: --include-ignored"]
fn k1_is_first_air_cell_of_types() {
    let f = fix();
    let g = *f.field.grid();
    let want = k1_of_cells(&f.cell, f.halo, g.nx, g.ny, g.nz);
    let bad = want.iter().zip(f.field.raw_k1()).filter(|(a, b)| a != b).count();
    let old_rule = f
        .field
        .raw_hc()
        .iter()
        .zip(f.field.raw_k1())
        .filter(|&(&h, &k)| {
            let kk = (((h as f64 - g.z_bot) / g.dz - 0.5).ceil().max(0.0) as usize).min(g.nz);
            kk as u32 != k
        })
        .count();
    eprintln!(
        "k1 по типам: {} из {} столбцов 400 м совпали; от hc иначе в {old_rule} столбцах",
        want.len() - bad,
        want.len()
    );
    assert_eq!(want.len(), 9216);
    assert_eq!(bad, 0, "k1 != первая cell == 1");
}

/// Окна 100/50 м: `k1` каждого уровня — по типам из `cut_level` на сетке уровня.
#[test]
#[ignore = "Онгудай с окнами, release: --include-ignored"]
fn k1_in_windows_follows_types() {
    let job = job_in(true);
    let pl = job.place.clone();
    let out = run_job(job).unwrap();
    assert!(out.levels.len() >= 3, "окна 50/100 м и область");
    let mut total = 0;
    for f in &out.levels {
        let g = *f.grid();
        let dom = Domain {
            x0: g.x0,
            y0: g.y0,
            nx: g.nx,
            ny: g.ny,
            dx: g.dx,
        };
        let (ht, _) = cut_level(&pl, &dom, g.nz, g.dz, g.z_bot).unwrap();
        let nz_h = (g.nz + 2) as i64;
        let want: Vec<u32> = ht
            .iter()
            .map(|&t| {
                let kf = (((t - g.z_bot) / g.dz).round() as i64 + 1).clamp(1, nz_h);
                ((kf - 1) as usize).min(g.nz) as u32
            })
            .collect();
        let bad = want.iter().zip(f.raw_k1()).filter(|(a, b)| a != b).count();
        eprintln!("k1 уровня dx={} м: {} из {} столбцов совпали", g.dx, want.len() - bad, want.len());
        assert_eq!(bad, 0, "dx {}: k1 != по типам", g.dx);
        total += want.len();
    }
    assert!(total > 9216);
}

// ---------------------------------------------------------------- (б) файл поля

#[test]
#[ignore = "Онгудай, release: --include-ignored"]
fn field_file_keeps_k1_and_reads_old_format() {
    let f = fix();
    let sf = SolvedField {
        location: "ongudai".into(),
        site: "s".into(),
        model_hash: "h".into(),
        key: json!({"k": 1}),
        levels: vec![(*f.field).clone()],
        names: vec!["dx400".into()],
        level_meta: vec![Map::new()],
    };
    let (hdr, data) = encode_solved(&sf, &json!({"k": 1}), &Map::new()).unwrap();
    let back = parse_solved(&hdr, &data).unwrap();
    let b = &back.levels[0];
    assert_eq!(b.raw_k1(), f.field.raw_k1(), "k1 поле → файл → поле");
    assert_eq!(b.raw_u().len(), f.field.raw_u().len());
    // файл старого формата: версия 1, без массива k1
    let mut h: Value = serde_json::from_str(&hdr).unwrap();
    assert_eq!(h["version"], json!(2));
    h["version"] = json!(1);
    h["levels"][0]["arrays"].as_object_mut().unwrap().remove("k1").expect("k1 в файле");
    let old = parse_solved(&h.to_string(), &data).unwrap();
    let o = &old.levels[0];
    let g = *f.field.grid();
    let from_hc = |c: usize| {
        let h = f.field.raw_hc()[c] as f64;
        (((h - g.z_bot) / g.dz - 0.5).ceil().max(0.0) as usize).min(g.nz) as u32
    };
    assert!((0..g.nx * g.ny).all(|c| o.raw_k1()[c] == from_hc(c)), "без k1 — от hc");
    let diff = (0..g.nx * g.ny).filter(|&c| o.raw_k1()[c] != f.field.raw_k1()[c]).count();
    eprintln!("файл версии 1 читается; k1 от hc отличается от k1 по типам в {diff} столбцах");
    assert!(diff > 0);
}

// ---------------------------------------------------------------- (в) выборка у земли

struct Probe {
    x: f64,
    yn: f64,
    windward: bool,
}

/// Точки на линиях вдоль ветра через самые крутые столбцы.
fn probes(f: &Field) -> Vec<Probe> {
    let g = *f.grid();
    let (nx, ny) = (g.nx, g.ny);
    let hc = f.raw_hc();
    // ветер области: среднее (u, v) на 3 клетки выше первой воздушной
    let (mut su, mut sv) = (0.0f64, 0.0f64);
    for c in 0..nx * ny {
        let k = (f.raw_k1()[c] as usize + 3).min(g.nz - 1);
        su += f.raw_u()[k * nx * ny + c] as f64;
        sv += f.raw_v()[k * nx * ny + c] as f64;
    }
    let n = (su * su + sv * sv).sqrt().max(1e-9);
    let (wx, wy) = (su / n, sv / n);
    let mut steep: Vec<(f64, usize, usize)> = Vec::new();
    for j in 6..ny - 6 {
        for i in 6..nx - 6 {
            let d = |a: usize, b: usize| (hc[a] as f64 - hc[b] as f64) / (2.0 * g.dx);
            let (gx, gy) = (d(j * nx + i + 1, j * nx + i - 1), d((j + 1) * nx + i, (j - 1) * nx + i));
            steep.push((gx.hypot(gy), i, j));
        }
    }
    steep.sort_by(|a, b| b.0.total_cmp(&a.0));
    let mut chosen: Vec<(usize, usize)> = Vec::new();
    for &(_, i, j) in &steep {
        if chosen.iter().all(|&(a, b)| (a as i64 - i as i64).abs().max((b as i64 - j as i64).abs()) >= 3) {
            chosen.push((i, j));
        }
        if chosen.len() == 25 {
            break;
        }
    }
    let mut pts = Vec::new();
    for (i, j) in chosen {
        let (cx, cy) = (g.x0 + (i as f64 + 0.5) * g.dx, g.y0 + (j as f64 + 0.5) * g.dx);
        for q in 0..40 {
            let s = (q as f64 - 19.5) * 100.0;
            let (x, yn) = (cx + s * wx, cy + s * wy);
            // наветренный склон: земля поднимается вдоль ветра
            let h = |dx: f64, dy: f64| f.ground_height((x + dx) as f32, (-(yn + dy)) as f32);
            let dh = (h(50.0 * wx, 50.0 * wy) - h(-50.0 * wx, -50.0 * wy)) / 100.0;
            pts.push(Probe {
                x,
                yn,
                windward: dh > 0.05,
            });
        }
    }
    pts
}

struct Prof {
    max_jump: f64,
    nan: usize,
    mono_frac: f64,
    windward: usize,
}

/// Профили `z_agl = 1…200 м` шагом 1 м: наибольший скачок вектора скорости между соседними
/// метрами, нечисловые значения, доля наветренных точек с неубывающим `|U_h|` на 1…50 м.
fn profile_stats(f: &Field, pts: &[Probe], min_a: usize) -> Prof {
    let (mut mj, mut nan, mut mono, mut wind) = (0.0f64, 0usize, 0usize, 0usize);
    let mut worst = None;
    for p in pts {
        let gh = f.ground_height(p.x as f32, (-p.yn) as f32);
        let mut prev: Option<[f32; 3]> = None;
        let (mut ok, mut last) = (true, 0.0f64);
        for a in 1..=200 {
            let v = f.sample([p.x as f32, (gh + a as f64) as f32, (-p.yn) as f32], gh as f32);
            if !v.iter().all(|x| x.is_finite()) {
                nan += 1;
                continue;
            }
            if let Some(q) = prev.filter(|_| a >= min_a) {
                let d = ((v[0] - q[0]) as f64).hypot(((v[1] - q[1]) as f64).hypot((v[2] - q[2]) as f64));
                if d > mj {
                    mj = d;
                    worst = Some((a, p.x, p.yn, gh, q, v));
                }
            }
            let sp = (v[0] as f64).hypot(v[2] as f64);
            if a <= 50 {
                if a > 1 && sp < last - 1e-3 {
                    ok = false;
                }
                last = sp;
            }
            prev = Some(v);
        }
        if p.windward {
            wind += 1;
            mono += ok as usize;
        }
    }
    eprintln!("  худший скачок: {worst:?}");
    Prof {
        max_jump: mj,
        nan,
        mono_frac: mono as f64 / wind.max(1) as f64,
        windward: wind,
    }
}

#[test]
#[ignore = "Онгудай, release: --include-ignored"]
fn near_ground_sampling_is_continuous() {
    let fx = fix();
    let pts = probes(&fx.field);
    assert!(pts.len() >= 1000);
    // A: земля лог-профиля — hc (как есть)
    let a = profile_stats(&fx.field, &pts, 2);
    // как до PT-10: k1 от hc, те же массивы
    let g0 = *fx.field.grid();
    let z0m: Vec<f64> = (0..g0.nx * g0.ny)
        .map(|c| {
            let p = [
                (g0.x0 + ((c % g0.nx) as f64 + 0.5) * g0.dx) as f32,
                0.0,
                (-(g0.y0 + ((c / g0.nx) as f64 + 0.5) * g0.dx)) as f32,
            ];
            fx.field.z0_at(p)
        })
        .collect();
    let old = Field::from_arrays(
        &g0,
        fx.field.raw_u().to_vec(),
        fx.field.raw_v().to_vec(),
        fx.field.raw_w_mech().to_vec(),
        fx.field.raw_w_conv().to_vec(),
        fx.field.raw_theta().to_vec(),
        fx.field.raw_hc().to_vec(),
        FieldMeta {
            z0: Z0::Map(z0m),
            ..FieldMeta::default()
        },
        Limits::default(),
    )
    .unwrap();
    let o = profile_stats(&old, &pts, 2);
    let a5 = profile_stats(&fx.field, &pts, 6);
    let o5 = profile_stats(&old, &pts, 6);
    eprintln!(
        "k1 от hc (как до PT-10): jumpOld={:.4} monoOld={:.4}; со 6 м над землёй: jumpOld6={:.4}, jumpA6={:.4}",
        o.max_jump, o.mono_frac, o5.max_jump, a5.max_jump
    );
    eprintln!(
        "вариант A (земля = hc): jumpA_all={:.4} (со 2 м) nanA={} monoA={:.4} (наветренных точек {})",
        a.max_jump, a.nan, a.mono_frac, a.windward
    );
    // Строки для приёмки. Скачок — со 6 м над землёй: ниже лог-закон при z0 ≈ 0,8 м и U ≈ 13 м/с
    // сам даёт > 1 м/с на метр (u*/κ·ln 2 ≈ 2 м/с), как и до PT-10 (`jumpOld`).
    assert_eq!(a.nan, 0, "NaN в выборке");
    assert!(a.mono_frac >= 0.95, "|U| у земли на наветренном склоне не убывает");
    eprintln!("nan={}", a.nan);
    eprintln!("max_jump_mps={:.4}", a5.max_jump);
    assert!(a5.max_jump <= 1.0);
}

// ---------------------------------------------------------------- (г) фазы

/// Воздушные клетки (`cell == 1`) замороженных колонн и из них нулевые (u, v, w, θ′ ровно 0).
fn zero_air(cell: &[f32], halo: (usize, usize, usize), fr: &dp_air::field::phase::assembly::PhaseResult, mech: bool) -> (usize, usize, usize) {
    let (hx, hy, hz) = halo;
    let fz = if mech { &fr.freeze_mech } else { &fr.freeze };
    let f = fz.field.as_ref().expect("поле заморозки");
    let nx = hx - 2;
    let (mut air, mut zero, mut cols) = (0usize, 0usize, 0usize);
    for c in 0..nx * (hy - 2) {
        if fz.mask[c] == 0 {
            continue;
        }
        cols += 1;
        let (j, i) = (c / nx, c % nx);
        for k in 1..hz - 1 {
            let q = (k * hy + j + 1) * hx + i + 1;
            if cell[q] != 1.0 {
                continue;
            }
            air += 1;
            if f.u[q] == 0.0 && f.v[q] == 0.0 && f.w[q] == 0.0 && f.th[q] == 0.0 {
                zero += 1;
            }
        }
    }
    (cols, air, zero)
}

#[test]
#[ignore = "Онгудай, release: --include-ignored"]
fn frozen_columns_have_no_zero_air_cells() {
    let mut tot = (0usize, 0usize);
    for (preset, hour) in [("strong", 12), ("medium", 12), ("weak", 12), ("weak", 4), ("medium", 4)] {
        let job = job_with(false, preset, hour);
        let [_, ch] = level_cases(&job).unwrap();
        let pr = phase_result(&job).unwrap();
        let halo = (ch.nxh, ch.nyh, ch.nzh);
        let cell = &ch.arrays["cell"];
        for (name, mech) in [("с нагревом", false), ("без нагрева", true)] {
            let (cols, air, zero) = zero_air(cell, halo, &pr, mech);
            eprintln!("{preset} {hour} ч, {name}: замороженных колонн {cols}, воздушных клеток {air}, из них нулевых {zero}");
            tot.0 += air;
            tot.1 += zero;
        }
    }
    assert!(tot.0 > 0, "заморозка есть");
    eprintln!("frozen_zero_frac={:.6}", tot.1 as f64 / tot.0 as f64);
}

// ---------------------------------------------------------------- (д) пограничный слой

fn pct(v: &mut [f64], q: f64) -> f64 {
    v.sort_by(|a, b| a.total_cmp(b));
    v[((v.len() - 1) as f64 * q) as usize]
}

/// `u*` и `desc` с `k1` по типам («после») и от `hc` («до»): те же массивы скоростей.
#[test]
#[ignore = "Онгудай, release: --include-ignored"]
fn boundary_layer_before_after() {
    let f = &fix().field;
    let g = *f.grid();
    let z0: Vec<f64> = (0..g.nx * g.ny)
        .map(|c| {
            let p = [
                (g.x0 + ((c % g.nx) as f64 + 0.5) * g.dx) as f32,
                0.0,
                (-(g.y0 + ((c / g.nx) as f64 + 0.5) * g.dx)) as f32,
            ];
            f.z0_at(p)
        })
        .collect();
    let meta = FieldMeta {
        z0: Z0::Map(z0),
        ..FieldMeta::default()
    };
    let before = Field::from_arrays(
        &g,
        f.raw_u().to_vec(),
        f.raw_v().to_vec(),
        f.raw_w_mech().to_vec(),
        f.raw_w_conv().to_vec(),
        f.raw_theta().to_vec(),
        f.raw_hc().to_vec(),
        meta,
        Limits::default(),
    )
    .unwrap();
    let shift: Vec<f64> = (0..g.nx * g.ny)
        .map(|c| f.raw_k1()[c] as f64 - before.raw_k1()[c] as f64)
        .collect();
    let (mut lo, mut z) = (0usize, 0usize);
    for &s in &shift {
        lo += (s < 0.0) as usize;
        z += (s == 0.0) as usize;
    }
    eprintln!("k1 по типам − k1 от hc: ниже в {lo}, равны в {z} из {} столбцов", shift.len());
    for (name, fld) in [("до (k1 от hc)", &before), ("после (k1 по типам)", &**f)] {
        let live: Vec<usize> = (0..g.nx * g.ny).filter(|&c| fld.raw_k1()[c] as usize + 1 < g.nz).collect();
        let mut us: Vec<f64> = live.iter().map(|&c| fld.raw_ustar()[c] as f64).collect();
        let mut de: Vec<f64> = live.iter().map(|&c| fld.raw_desc()[c] as f64).collect();
        let mut uo: Vec<f64> = live.iter().map(|&c| fld.raw_uout()[c] as f64).collect();
        eprintln!(
            "{name}: u* p10/p50/p90/max {:.3}/{:.3}/{:.3}/{:.3}; U_out p50/p90 {:.2}/{:.2}; desc p50/p90/max {:.3}/{:.3}/{:.3}",
            pct(&mut us.clone(), 0.1),
            pct(&mut us.clone(), 0.5),
            pct(&mut us.clone(), 0.9),
            pct(&mut us, 1.0),
            pct(&mut uo.clone(), 0.5),
            pct(&mut uo, 0.9),
            pct(&mut de.clone(), 0.5),
            pct(&mut de.clone(), 0.9),
            pct(&mut de, 1.0),
        );
        assert!(fld.raw_ustar().iter().all(|x| x.is_finite()));
    }
}
