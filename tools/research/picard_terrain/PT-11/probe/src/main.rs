//! PT-11: ядра термиков по моментам случая (AirModel::cores) для сравнения «до/после».
//! Использование: pt11-probe cores <case.json> [<place.json>] [--configs dir]
use dp_air::AirModel;
use dp_stand::setup::{OpenArgs, go_to_model, open_formula};
use serde_json::json;
use std::path::PathBuf;
use std::time::Duration;

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args[1] == "heat" {
        return heat(&args[2]);
    }
    let case = PathBuf::from(&args[2]);
    let place = args.get(3).filter(|s| !s.starts_with("--")).map(PathBuf::from);
    let configs = PathBuf::from("configs");
    let a = OpenArgs { case: &case, place: place.as_deref(), model: "formula", configs: &configs, timeout_s: 900.0 };
    let (mut model, c) = open_formula(&a)?;
    for t in c.times_s.clone() {
        go_to_model(&mut model as &mut dyn AirModel, t, Duration::from_secs(900))?;
        let mut cores = Vec::new();
        model.cores([0.0; 3], 1.0e9, &mut cores);
        let mut nan = 0usize;
        let list: Vec<_> = cores.iter().map(|k| {
            for v in [k.x, k.z, k.y_src, k.top, k.w, k.radius] { if !v.is_finite() { nan += 1; } }
            json!({"id":k.id,"flags":k.flags,"x":k.x,"z":k.z,"y_src":k.y_src,"top":k.top,"w":k.w,"radius":k.radius})
        }).collect();
        println!("{}", json!({"t":t,"n":cores.len(),"nan":nan,"cores":list}));
    }
    Ok(())
}

/// Баланс тепла Онгудая 400 м (PT-11, риск 1): по столбцу Σ Q·vf·dz против h0 = heat/ρcp.
/// Как tests/cut_game.rs (`job_in`, `level_cases`), погода без сеток климата. Только «после» (vf есть).
fn heat(repo: &str) -> Result<(), String> {
    use dp_air::field::case_prepare::RHO_CP;
    use dp_air::field::runtime::*;
    use dp_air::field::weather_core::{Domain, field_weather, hour_at, WeatherInputs};
    use dp_air::weather::{ClimateGrids, Weather};
    use dp_air::{Conditions, Configs};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicU32};
    let repo = PathBuf::from(repo);
    let cfgs = dp_stand::setup::load_configs(&repo.join("configs"))?;
    let pl = dp_air::fixtures::read_place(&repo.join("tests/fixtures/wind/places/ongudai.json")).map_err(|e| e.to_string())?;
    let c = Conditions::from_json(r#"{"preset":"strong","start_hour":12,"speed":1,"blend_s":null,"rebuild":false}"#).map_err(|e| e.to_string())?;
    let mut cfg = RtCfg::from_configs(&cfgs).map_err(|e| e.to_string())?;
    cfg.faults = Faults { coarse: false, fail_pass: None, no_phase: false, no_windows: true };
    let weather = Arc::new(Weather::new(&cfgs, ClimateGrids::none()).map_err(|e| e.to_string())?);
    let inputs = WeatherInputs::from_conditions(&c, &cfgs).map_err(|e| e.to_string())?;
    let rec = CondRec::new(&inputs, hour_at(&c, 0.0));
    let job = JobIn {
        weather: Some(weather), cfg: Arc::new(cfg), configs: Arc::new(cfgs.clone()), place: Arc::new(pl), cond: c.clone(),
        rec, loading: true, focus: None, warm: None, cancel: Arc::new(AtomicBool::new(false)),
        progress: Arc::new(AtomicU32::new(0)), stage: Arc::new(StageCounter::default()),
        cache: None, place_hash: Arc::new(std::sync::OnceLock::new()), clip: None,
        win_fail: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
    };
    let dom: Domain = domain_for(&job.place, &job.cfg).map_err(|e| e.to_string())?;
    let climate = PlaceClimate::of(&job.cfg.climate, job.weather.as_deref());
    let fw = field_weather(&job.cond, &job.place, &job.cfg.wc, &job.configs, &climate, job.rec.hour, &dom).map_err(|e| e.to_string())?;
    let [_cm, ch] = level_cases(&job).map_err(|e| format!("{e:?}"))?;
    let (nx, ny, nz) = (ch.nx, ch.ny, ch.nz);
    let (nxh, nyh) = (ch.nxh, ch.nyh);
    let q = &ch.arrays["Q"];
    let vf = &ch.arrays["vf"];
    let dz = ch.dz as f64;
    let n_plane = nxh * nyh;
    let mut rows = Vec::new();
    let (mut s_vf, mut s_plain, mut s_h0, mut nbad, mut n_cut_cols, mut nonfinite) = (0.0, 0.0, 0.0, 0usize, 0usize, 0usize);
    let (mut worst, mut ratios) = (0.0f64, Vec::new());
    let taper_cells = 12usize;
    for j in taper_cells..ny - taper_cells {
        for i in taper_cells..nx - taper_cells {
            let h0 = fw.heat[j * nx + i] / RHO_CP;
            let (mut a, mut b) = (0.0f64, 0.0f64);
            let mut cut = false;
            for k in 0..nz + 2 {
                let idx = k * n_plane + (j + 1) * nxh + (i + 1);
                let (qq, v) = (q[idx] as f64, vf[idx] as f64);
                if !qq.is_finite() || !v.is_finite() { nonfinite += 1; continue; }
                a += qq * v * dz; b += qq * dz;
                if qq != 0.0 && v < 1.0 { cut = true; }
            }
            if cut { n_cut_cols += 1; }
            if h0.abs() > 1e-9 {
                ratios.push(a / h0);
                worst = f64::max(worst, (a / h0 - 1.0).abs());
            } else if a.abs() > 1e-9 { nbad += 1; }
            s_vf += a; s_plain += b; s_h0 += h0;
            if (i + j) % 7 == 0 && rows.len() < 20 { rows.push(serde_json::json!({"i":i,"j":j,"h0":h0,"sum_q_vf_dz":a,"sum_q_dz":b})); }
        }
    }
    ratios.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let pct = |p: f64| ratios[((ratios.len() - 1) as f64 * p) as usize];
    println!("{}", serde_json::json!({
        "domain": [nx, ny, nz], "dz": dz, "columns": ratios.len(), "cut_heated_columns": n_cut_cols,
        "total_h0": s_h0, "total_sum_q_vf_dz": s_vf, "total_sum_q_dz": s_plain,
        "ratio_total_vf": s_vf / s_h0, "ratio_total_plain": s_plain / s_h0,
        "ratio_vf_quantiles": {"min": ratios[0], "p5": pct(0.05), "p50": pct(0.5), "p95": pct(0.95), "max": ratios[ratios.len()-1]},
        "worst_abs_dev": worst, "zero_h0_nonzero_q": nbad, "nonfinite": nonfinite, "samples": rows,
    }));
    Ok(())
}
