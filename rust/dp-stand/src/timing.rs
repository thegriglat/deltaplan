//! `timing`: журнал задачи поля (`JobReport`) на каждый момент случая - время загрузки и пересчёта
//! поля без Godot. Кеш полей на диске стенд не включает (`set_cache_dir` не вызывается), поэтому
//! `source` всегда `Computed` - это замер расчёта.
use dp_stand::setup::{OpenArgs, go_to_model, open_formula};
use dp_air::AirModel;
use dp_air::field::clipmap::WinReport;
use serde_json::{Value, json};
use std::time::Duration;

fn win(w: &WinReport) -> Value {
    json!({
        "dx": w.dx, "x0": w.x0, "y0": w.y0, "warm": w.warm, "iters": w.iters,
        "stop": w.stop.iter().map(|s| format!("{s:?}")).collect::<Vec<_>>(),
        "div_rms": w.div_rms, "corr": w.corr, "secs": w.secs,
    })
}

/// Печатает по строке json на момент; первый момент - `load`, остальные - `recalc`.
pub fn run(a: &OpenArgs, times: Option<f64>) -> Result<(), String> {
    let (mut model, case) = open_formula(a)?;
    let ts = match times {
        Some(t) => vec![t],
        None => case.times_s.clone(),
    };
    let timeout = Duration::from_secs_f64(a.timeout_s.max(0.0));
    for (k, t) in ts.iter().enumerate() {
        go_to_model(&mut model as &mut dyn AirModel, *t, timeout)?;
        let r = model.report().ok_or("no job report after Ready")?;
        let passes: Vec<Value> = r
            .passes
            .iter()
            .map(|p| {
                json!({
                    "iters": p.iters, "coarse_iters": p.coarse_iters,
                    "start": format!("{:?}", p.start), "notes": p.notes,
                    "stop": p.stop.iter().map(|s| format!("{s:?}")).collect::<Vec<_>>(),
                    "div_rms": p.div_rms, "omega_fallback": p.omega_fallback,
                    "nonconv_fallback": p.nonconv_fallback, "secs": p.secs,
                    "phases": p.phases, "phase_s": p.phase_s, "frozen_frac": p.frozen_frac,
                    "nonconv_cols": p.nonconv_cols,
                    "windows": p.windows.iter().map(win).collect::<Vec<_>>(),
                    "win_error": p.win_error, "win_s": p.win_s,
                })
            })
            .collect();
        let line = json!({
            "t": t, "kind": if k == 0 { "load" } else { "recalc" },
            "source": format!("{:?}", r.source), "wall_s": r.wall_s, "passes": passes,
            "windows": r.windows.iter().map(win).collect::<Vec<_>>(),
            "windows_error": r.windows_error, "notes": r.notes,
            "threads": rayon::current_num_threads(),
        });
        println!("{line}");
    }
    Ok(())
}
