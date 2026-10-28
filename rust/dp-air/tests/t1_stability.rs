//! RW-6z: опыт «неустойчивость задачи или ошибка переноса» для открытых полей T1.
//!
//! Только опыт: физика и допуски не меняются. Тесты `stab_*` — `#[ignore]`, release; приёмка их
//! пропускает (`--skip stab_`). Порядок работы — `tools/research/rust_wind_t1_stability/README.md`.
//!
//! - `stab_run`: `RW6Z_VARIANT` (base|chunk1000|pert_u10|pert_t), `RW6Z_RAW` (каталог сырья вне
//!   репозитория), `RW6Z_FIELDS` (необяз., `loc/site,...`). Считает поля `Formula` как `t1_field`
//!   в `acceptance.rs` (копия вспомогательного кода) и пишет по полю: `meta.json`, `masks.bin`
//!   (маска заморозки с нагревом, без нагрева, класс фазы колонны области), `<уровень>.f32`
//!   (u, v, w_mech, w_conv, θ′ подряд, f32 LE).
//! - `stab_compare`: `RW6Z_RAW`, `RW6Z_DIFFS` (jsonl) — сравнения base_vs_gpu и варианты против base
//!   по классам клеток.
#![allow(clippy::needless_range_loop)]
use dp_air::field::baked::parse_baked;
use dp_air::field::runtime::*;
use dp_air::field::weather_core::{WeatherInputs, hour_at};
use dp_air::fixtures::read_place;
use dp_air::{AirModel, Conditions, Configs, Focus, Formula, Place, State};
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

const FIELDS: [(&str, &str); 6] = [
    ("training_island", "ridge_west"),
    ("training_island", "thermal_plain"),
    ("volcano_island", "plateau_landing"),
    ("volcano_island", "thermal_slope"),
    ("training_island", "lee_bowl"),
    ("training_island", "landing_hill"),
];

const NO_WIN: Faults = Faults {
    coarse: false,
    fail_pass: None,
    no_phase: false,
    no_windows: true,
};

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

fn place(name: &str) -> Place {
    read_place(&repo().join(format!("tests/fixtures/wind/places/{name}.json"))).unwrap()
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

/// Условия набора погоды запечённого поля (`AirBakedField.conditions_of`); `w` может быть
/// возмущён вызывающим.
fn baked_conditions(w: &Value) -> Conditions {
    let num = |k: &str| w[k].as_f64().unwrap_or_else(|| panic!("weather.{k}"));
    let inflow = w["wind_ref"].as_str().unwrap_or("start") == "inflow";
    Conditions::from_json(
        &json!({
            "forecast": {
                "temperature_c": num("temperature_c"),
                "wind_speed_kmh": num("wind_speed_ms") * 3.6,
                "wind_from_deg": num("wind_from_deg"),
                "sky": w["sky"].as_str().unwrap(),
            },
            "start_hour": num("start_hour"),
            "speed": 1.0,
            "quantum_h": 0.5,
            "blend_s": null,
            "rebuild": false,
            "inflow_mode": if inflow { "inflow" } else { "start" },
        })
        .to_string(),
    )
    .unwrap()
}

fn half_f16_ulp(x: f64) -> f64 {
    if x == 0.0 || !x.is_finite() {
        return 0.0;
    }
    let e = x.abs().log2().floor().max(-14.0);
    0.5 * (e - 10.0).exp2()
}

fn max_abs(a: &[f32]) -> f64 {
    a.iter().map(|x| f64::from(x.abs())).fold(0.0, f64::max)
}

fn out_root() -> PathBuf {
    PathBuf::from(std::env::var("RW6Z_RAW").expect("RW6Z_RAW"))
}

fn fdir(variant: &str, loc: &str, site: &str) -> PathBuf {
    out_root().join(variant).join(format!("{loc}__{site}"))
}

fn write_f32(path: &Path, chans: [&[f32]; 5]) {
    let mut b = Vec::with_capacity(chans[0].len() * 20);
    for c in chans {
        for x in c {
            b.extend_from_slice(&x.to_le_bytes());
        }
    }
    std::fs::write(path, b).unwrap();
}

fn read_f32(path: &Path) -> [Vec<f32>; 5] {
    let b = std::fs::read(path).unwrap();
    let n = b.len() / 20;
    let all: Vec<f32> = b
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    std::array::from_fn(|i| all[i * n..(i + 1) * n].to_vec())
}

fn stop_name(s: impl std::fmt::Debug) -> String {
    format!("{s:?}")
}

fn conv_ok(s: &str) -> bool {
    s == "Converged" || s == "AllFrozen"
}

fn run_field(variant: &str, loc: &str, site: &str) {
    let dir = repo().join("data/locations").join(loc).join("air");
    let head = std::fs::read_to_string(dir.join(format!("{site}.json"))).unwrap();
    let bin = std::fs::read(dir.join(format!("{site}.bin"))).unwrap();
    let baked = parse_baked(&head, &bin).unwrap_or_else(|e| panic!("{loc}/{site}: {}", e.msg));
    let key = &baked.key;
    let mut weather = key["weather"].clone();
    match variant {
        "pert_u10" => {
            let v = weather["wind_speed_ms"].as_f64().unwrap();
            weather["wind_speed_ms"] = json!(v * (1.0 + 1e-6));
        }
        "pert_t" => {
            let t = weather["temperature_c"].as_f64().unwrap();
            weather["temperature_c"] = json!(t + 1e-6 * (t + 273.15));
        }
        "base" | "chunk1000" => {}
        v => panic!("variant {v}"),
    }
    let cond = baked_conditions(&weather);
    let start = key["start"].as_array().unwrap();
    let (sx, sz) = (
        start[0].as_f64().unwrap() as f32,
        start[1].as_f64().unwrap() as f32,
    );
    let cfg = configs_with(|v| {
        v["air"]["deterministic"] = json!(true);
        v["air"]["tol_scale"] = json!(1.0);
        v["air"]["threads"] = json!(8);
        v["air"]["timeout_s"] = json!(1800.0);
    });
    let pl = place(loc);
    let focus = Focus {
        pos: [sx, ground_height(&pl, sx, sz) + 10.0, sz],
        weight: 1.0,
    };
    let t0 = Instant::now();
    let mut m = Formula::new();
    m.configure(&cfg, 1).unwrap();
    m.set_conditions(&cond).unwrap();
    m.set_focuses(&[focus]).unwrap();
    m.load_place(pl).unwrap();
    wait_ready(&mut m, 1800.0);
    let wall = t0.elapsed().as_secs_f64();
    let r = m.report().unwrap();
    assert!(
        r.windows_error.is_none(),
        "{loc}/{site}: {:?}",
        r.windows_error
    );
    assert_eq!(r.source, Source::Computed);
    let got = m.clip().expect("окна клипмапа").levels();
    assert_eq!(got.len(), baked.levels.len());
    let out = fdir(variant, loc, site);
    std::fs::create_dir_all(&out).unwrap();

    // фазы области: маски заморозки, класс колонны, статистика
    let last_k = r.passes.last().unwrap().k;
    let jin = {
        let mut c = RtCfg::from_configs(&cfg).unwrap();
        c.faults = NO_WIN;
        let inputs = WeatherInputs::from_conditions(&cond, &cfg).unwrap();
        let rec = CondRec::new(&inputs, &cond, hour_at(&cond, 0.0));
        JobIn {
            cfg: Arc::new(c),
            configs: Arc::new(cfg.clone()),
            place: Arc::new(place(loc)),
            cond: cond.clone(),
            rec,
            loading: false,
            k_mem: None,
            inflow_k: 1.0,
            focus: Some([sx, sz]),
            warm: None,
            cancel: Arc::new(AtomicBool::new(false)),
            progress: Arc::new(AtomicU32::new(0)),
            stage: Arc::new(StageCounter::default()),
            baked: Arc::new(Vec::new()),
            cache: None,
            place_hash: Arc::new(OnceLock::new()),
            clip: None,
            win_fail: Arc::new(AtomicUsize::new(0)),
        }
    };
    let ph = phase_result(&jin, last_k).unwrap_or_else(|_| panic!("phase_result"));
    let area = got.last().unwrap().grid().clone();
    let n_col = area.nx * area.ny;
    assert_eq!(
        ph.freeze.mask.len(),
        n_col,
        "маска области не по сетке dx400"
    );
    assert_eq!(ph.freeze_mech.mask.len(), n_col);
    let wts = &ph.maps.heat.weights;
    let class: Vec<u8> = (0..n_col)
        .map(|c| {
            let mut b = (0usize, -1.0f64);
            for k in 0..7 {
                let w = wts[k * n_col + c];
                if w > b.1 {
                    b = (k, w);
                }
            }
            b.0 as u8
        })
        .collect();
    let mut mb = Vec::new();
    mb.extend_from_slice(&ph.freeze.mask);
    mb.extend_from_slice(&ph.freeze_mech.mask);
    mb.extend_from_slice(&class);
    std::fs::write(out.join("masks.bin"), mb).unwrap();

    // уровни, статусы
    let mut levels = Vec::new();
    let mut passes = Vec::new();
    for (i, p) in r.passes.iter().enumerate() {
        let sm = stop_name(p.stop[0]);
        let sh = stop_name(p.stop[1]);
        passes.push(json!({"level": "dx400", "pass": i, "k": p.k, "status_mech": sm, "status_heat": sh,
            "status": if conv_ok(&sm) && conv_ok(&sh) { "Converged".to_string() } else if !conv_ok(&sh) { sh.clone() } else { sm.clone() },
            "iters_mech": p.iters[0], "iters_heat": p.iters[1],
            "div_rms": p.div_rms[0].max(p.div_rms[1]), "div_rms_mech": p.div_rms[0], "div_rms_heat": p.div_rms[1],
            "frozen_frac": p.frozen_frac, "coarse_iters": p.coarse_iters}));
    }
    let lastp = r.passes.last().unwrap();
    for (li, f) in got.iter().enumerate() {
        let g = f.grid();
        let name = baked.names[li].clone();
        let (nonconv, st) = if li + 1 == got.len() {
            let a = [stop_name(lastp.stop[0]), stop_name(lastp.stop[1])];
            (!(conv_ok(&a[0]) && conv_ok(&a[1])), a)
        } else {
            let w = r
                .windows
                .iter()
                .find(|w| (w.dx - g.dx).abs() < 1e-6)
                .unwrap_or_else(|| panic!("нет отчёта окна dx {}", g.dx));
            passes.push(json!({"level": name, "pass": r.passes.len() - 1, "status_mech": stop_name(w.stop[0]), "status_heat": stop_name(w.stop[1]),
                "status": if conv_ok(&stop_name(w.stop[0])) && conv_ok(&stop_name(w.stop[1])) {"Converged".to_string()} else if !conv_ok(&stop_name(w.stop[1])) {stop_name(w.stop[1])} else {stop_name(w.stop[0])},
                "iters_mech": w.iters[0], "iters_heat": w.iters[1],
                "div_rms": w.div_rms[0].max(w.div_rms[1]), "div_rms_mech": w.div_rms[0], "div_rms_heat": w.div_rms[1], "warm": w.warm}));
            let a = [stop_name(w.stop[0]), stop_name(w.stop[1])];
            (!(conv_ok(&a[0]) && conv_ok(&a[1])), a)
        };
        levels.push(json!({"name": name, "nx": g.nx, "ny": g.ny, "nz": g.nz, "dx": g.dx, "x0": g.x0, "y0": g.y0,
            "nonconv": nonconv, "stop": st}));
        write_f32(
            &out.join(format!("{name}.f32")),
            [
                f.raw_u(),
                f.raw_v(),
                f.raw_w_mech(),
                f.raw_w_conv(),
                f.raw_theta(),
            ],
        );
    }
    let st = &ph.stats;
    let meta = json!({
        "loc": loc, "site": site, "variant": variant, "wall_s": wall,
        "k": r.passes.iter().map(|p| p.k).collect::<Vec<_>>(),
        "k_final": m.inflow_k(), "k_file": baked.inflow_k,
        "passes": passes, "levels": levels,
        "stats": {"u10": st.u10, "fr": st.fr, "n_bv": st.n_bv, "u_over_n": st.u_over_n,
            "frozen_frac": st.frozen_frac, "frozen_frac_mech": st.frozen_frac_mech,
            "phase_frac": st.phase_frac, "full_mech": st.full_mech, "u_sat": st.u_sat,
            "wstar_max": st.wstar_max},
        "wind_speed_ms_used": weather["wind_speed_ms"],
    });
    std::fs::write(
        out.join("meta.json"),
        serde_json::to_string_pretty(&meta).unwrap(),
    )
    .unwrap();
    eprintln!(
        "STAB {variant} {loc}/{site}: стена {wall:.1} с, k {:?}",
        meta["k"]
    );
}

#[test]
#[ignore = "опыт RW-6z, release, RW6Z_VARIANT и RW6Z_RAW"]
fn stab_run() {
    let variant = std::env::var("RW6Z_VARIANT").expect("RW6Z_VARIANT");
    let only = std::env::var("RW6Z_FIELDS").ok();
    for (loc, site) in FIELDS {
        if let Some(o) = &only
            && !o.split(',').any(|x| x == format!("{loc}/{site}"))
        {
            continue;
        }
        run_field(&variant, loc, site);
    }
}

// ------------------------------------------------------------------ сравнение

struct Lvl {
    chans: [Vec<f32>; 5],
}

struct Meta {
    v: Value,
}

fn load(variant: &str, loc: &str, site: &str) -> Option<(Meta, Vec<Lvl>, Vec<u8>)> {
    let d = fdir(variant, loc, site);
    let mt = std::fs::read_to_string(d.join("meta.json")).ok()?;
    let v: Value = serde_json::from_str(&mt).unwrap();
    let lv = v["levels"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| Lvl {
            chans: read_f32(&d.join(format!("{}.f32", l["name"].as_str().unwrap()))),
        })
        .collect();
    let masks = std::fs::read(d.join("masks.bin")).unwrap();
    Some((Meta { v }, lv, masks))
}

const CH: [&str; 5] = ["u", "v", "w_mech", "w_conv", "theta"];

#[derive(Default, Clone)]
struct Acc {
    n: usize,
    max: f64,
    sq: f64,
    over: usize,
}

#[test]
#[ignore = "опыт RW-6z, сведение, RW6Z_RAW и RW6Z_DIFFS"]
fn stab_compare() {
    let outp = std::env::var("RW6Z_DIFFS").expect("RW6Z_DIFFS");
    let mut out = std::fs::File::create(&outp).unwrap();
    let variants = ["chunk1000", "pert_u10", "pert_t"];
    for (loc, site) in FIELDS {
        let Some((bm, base, masks)) = load("base", loc, site) else {
            continue;
        };
        let dir = repo().join("data/locations").join(loc).join("air");
        let head = std::fs::read_to_string(dir.join(format!("{site}.json"))).unwrap();
        let bin = std::fs::read(dir.join(format!("{site}.bin"))).unwrap();
        let baked = parse_baked(&head, &bin).unwrap();
        let others: Vec<(&str, Vec<Lvl>)> = variants
            .iter()
            .filter_map(|v| load(v, loc, site).map(|(_, l, _)| (*v, l)))
            .collect();
        let lv = bm.v["levels"].as_array().unwrap();
        let na = lv.last().unwrap();
        let (anx, any, adx, ax0, ay0) = (
            na["nx"].as_u64().unwrap() as usize,
            na["ny"].as_u64().unwrap() as usize,
            na["dx"].as_f64().unwrap(),
            na["x0"].as_f64().unwrap(),
            na["y0"].as_f64().unwrap(),
        );
        let ncol = anx * any;
        let (fm_heat, fm_mech) = (&masks[..ncol], &masks[ncol..2 * ncol]);
        for (li, l) in lv.iter().enumerate() {
            let name = l["name"].as_str().unwrap();
            let (nx, ny, nz) = (
                l["nx"].as_u64().unwrap() as usize,
                l["ny"].as_u64().unwrap() as usize,
                l["nz"].as_u64().unwrap() as usize,
            );
            let (dx, x0, y0) = (
                l["dx"].as_f64().unwrap(),
                l["x0"].as_f64().unwrap(),
                l["y0"].as_f64().unwrap(),
            );
            let nonconv = l["nonconv"].as_bool().unwrap();
            let gf = &baked.levels[li];
            let gpu: [&[f32]; 5] = [
                gf.raw_u(),
                gf.raw_v(),
                gf.raw_w_mech(),
                gf.raw_w_conv(),
                gf.raw_theta(),
            ];
            let u0 = gf
                .raw_u()
                .iter()
                .zip(gf.raw_v())
                .map(|(u, v)| f64::from(*u).hypot(f64::from(*v)))
                .fold(0.0, f64::max);
            let bound: [f64; 5] = std::array::from_fn(|c| {
                if c < 4 {
                    1e-3 * u0 + half_f16_ulp(max_abs(gpu[c]))
                } else {
                    0.05 + half_f16_ulp(max_abs(gpu[4]))
                }
            });
            // колонна области каждой клетки уровня
            let col_of = |i: usize, j: usize| -> usize {
                let x = x0 + (i as f64 + 0.5) * dx;
                let y = y0 + (j as f64 + 0.5) * dx;
                let ia = (((x - ax0) / adx).floor().max(0.0) as usize).min(anx - 1);
                let ja = (((y - ay0) / adx).floor().max(0.0) as usize).min(any - 1);
                ja * anx + ia
            };
            let n = nx * ny * nz;
            let plane = nx * ny;
            assert_eq!(base[li].chans[0].len(), n);
            // класс клетки: 0 picard-conv_both, 1 picard-nonconv, 2 mech (по каналу — для w_mech маска «без нагрева»)
            let cls = |c: usize, idx: usize| -> u8 {
                let k = idx % plane;
                let (j, i) = (k / nx, k % nx);
                let col = col_of(i, j);
                let frozen = if c == 2 { fm_mech[col] } else { fm_heat[col] };
                if frozen != 0 {
                    2
                } else if nonconv {
                    1
                } else {
                    0
                }
            };
            let sets: [(&str, fn(u8) -> bool); 5] = [
                ("picard", |c| c != 2),
                ("mech", |c| c == 2),
                ("all", |_| true),
                ("conv_both", |c| c == 0),
                ("nonconv", |c| c == 1),
            ];
            // сравнения
            let mut cmps: Vec<(String, Vec<&[f32]>)> = Vec::new();
            cmps.push(("base_vs_gpu".into(), gpu.to_vec()));
            for (v, ls) in &others {
                cmps.push((
                    format!("{v}_vs_base"),
                    ls[li].chans.iter().map(|c| c.as_slice()).collect(),
                ));
            }
            // огибающая блуждания по |Δ(u,v)| вариантов против base
            let mut env = vec![0.0f64; n];
            for (_, ls) in &others {
                for (idx, e) in env.iter_mut().enumerate() {
                    let d = f64::from(ls[li].chans[0][idx] - base[li].chans[0][idx])
                        .hypot(f64::from(ls[li].chans[1][idx] - base[li].chans[1][idx]));
                    *e = e.max(d);
                }
            }
            for (cname, other) in &cmps {
                for (sname, sel) in sets {
                    let mut ch = serde_json::Map::new();
                    for c in 0..5 {
                        let mut a = Acc::default();
                        for idx in 0..n {
                            if !sel(cls(c, idx)) {
                                continue;
                            }
                            let d = f64::from(base[li].chans[c][idx] - other[c][idx]).abs();
                            // для base_vs_gpu: base - gpu; для вариантов: base - variant
                            a.n += 1;
                            a.max = a.max.max(d);
                            a.sq += d * d;
                            if d > bound[c] {
                                a.over += 1;
                            }
                        }
                        ch.insert(
                            CH[c].into(),
                            json!({"max": a.max, "x_tol": a.max / bound[c], "rms": if a.n > 0 {(a.sq / a.n as f64).sqrt()} else {0.0},
                                "n_over_tol": a.over, "n": a.n, "tol": bound[c]}),
                        );
                    }
                    // горизонтальная скорость: размах блуждания и доли в 10/20 % и в огибающей
                    let (mut hmax, mut hsq, mut hn) = (0.0f64, 0.0f64, 0usize);
                    let mut fr = [0usize; 5];
                    for idx in 0..n {
                        if !sel(cls(0, idx)) {
                            continue;
                        }
                        let d = f64::from(base[li].chans[0][idx] - other[0][idx])
                            .hypot(f64::from(base[li].chans[1][idx] - other[1][idx]));
                        hn += 1;
                        hmax = hmax.max(d);
                        hsq += d * d;
                        let loc_u = f64::from(gpu[0][idx]).hypot(f64::from(gpu[1][idx]));
                        let loc_b = f64::from(base[li].chans[0][idx])
                            .hypot(f64::from(base[li].chans[1][idx]));
                        let loc = if cname == "base_vs_gpu" { loc_u } else { loc_b }.max(0.1);
                        if d <= 0.10 * u0 {
                            fr[0] += 1;
                        }
                        if d <= 0.20 * u0 {
                            fr[1] += 1;
                        }
                        if d <= 0.10 * loc {
                            fr[2] += 1;
                        }
                        if d <= 0.20 * loc {
                            fr[3] += 1;
                        }
                        if d <= env[idx] {
                            fr[4] += 1;
                        }
                    }
                    // классы фаз колонн (A,B,C,D,F,G,H): клетки, где хоть один канал сверх допуска
                    let mut phase_over = [0usize; 7];
                    if sname == "all" && cname == "base_vs_gpu" {
                        for idx in 0..n {
                            let k = idx % plane;
                            let col = col_of(k % nx, k / nx);
                            if (0..5).any(|c| {
                                f64::from(base[li].chans[c][idx] - other[c][idx]).abs() > bound[c]
                            }) {
                                phase_over[usize::from(masks[2 * ncol + col]).min(6)] += 1;
                            }
                        }
                    }
                    let hn_f = hn.max(1) as f64;
                    let hrms = (hsq / hn_f).sqrt();
                    let rec = json!({
                        "loc": loc, "site": site, "level": name, "cmp": cname, "cells": sname,
                        "u0": u0, "ch": ch, "phase_over_tol": phase_over,
                        "hspeed": {"n": hn, "max": hmax, "rms": hrms, "max_over_u0": hmax / u0, "rms_over_u0": hrms / u0,
                            "frac_in_10pct_u0": fr[0] as f64 / hn_f, "frac_in_20pct_u0": fr[1] as f64 / hn_f,
                            "frac_in_10pct_local": fr[2] as f64 / hn_f, "frac_in_20pct_local": fr[3] as f64 / hn_f,
                            "frac_in_envelope": fr[4] as f64 / hn_f},
                    });
                    writeln!(out, "{rec}").unwrap();
                }
            }
        }
    }
}
