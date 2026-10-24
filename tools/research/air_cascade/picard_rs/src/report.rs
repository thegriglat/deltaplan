//! Result file R2 (`picard-rs-result`, version 3: phases, `t_s`, stop reason, snapshots) and the deviation against the reference
//! solution `sol_*` of the case.

use crate::case::Case;
use crate::solver::{Check, Picard, SolveOut};
use anyhow::Result;
use serde_json::{Value, json};
use std::path::Path;

/// Deviation of the current fields from the reference solution of the case.
pub struct Dev {
    pub u0: f64,
    pub u_rel: f64,
    pub th_abs: f64,
    pub p_rel: f64,
    pub div_rms: f64,
    pub div_rms_ref: f64,
    /// Cell-centre deviation (max, rms) of u, v, w (m/s) and θ′ (K) in the crop window, all levels.
    pub crop: Option<[(f64, f64); 4]>,
}

fn max_abs_diff(a: &[f32], b: &[f32]) -> f64 {
    a.iter()
        .zip(b)
        .map(|(x, y)| (f64::from(*x) - f64::from(*y)).abs())
        .fold(0.0, |m, d| {
            if d.is_nan() || m.is_nan() {
                f64::NAN
            } else {
                m.max(d)
            }
        })
}

fn max_abs(a: &[f32]) -> f64 {
    a.iter().map(|x| f64::from(*x).abs()).fold(0.0, f64::max)
}

/// RMS of the divergence over air cells in `f64` from `f32` velocities (like `_div_cpu_f64`).
pub fn div_rms_f64(s: &Picard, u: &[f32], v: &[f32], w: &[f32]) -> f64 {
    let k = &s.k;
    let mut sum = 0.0f64;
    let mut n = 0usize;
    for kk in 0..k.nz {
        for j in 0..k.ny {
            for i in 0..k.nx {
                let g = ((kk + 1) * k.nyh + j + 1) * k.nxh + i + 1;
                if k.cell[g] != 1 {
                    continue;
                }
                let d = (f64::from(u[g + 1]) - f64::from(u[g])) / f64::from(k.dx)
                    + (f64::from(v[g + k.nxh]) - f64::from(v[g])) / f64::from(k.dx)
                    + (f64::from(w[g + k.nxh * k.nyh]) - f64::from(w[g])) / f64::from(k.dz);
                sum += d * d;
                n += 1;
            }
        }
    }
    (sum / n.max(1) as f64).sqrt()
}

/// Deviation of cell-centre u, v, w (faces averaged) and θ′ in the crop window against `sol_*`.
fn crop_dev(c: &Case, s: &Picard) -> Result<Option<[(f64, f64); 4]>> {
    let Some(cr) = c.crop else { return Ok(None) };
    let k = &s.k;
    let refs = [
        c.arr("sol_u")?,
        c.arr("sol_v")?,
        c.arr("sol_w")?,
        c.arr("sol_th")?,
    ];
    let mine: [&[f32]; 4] = [&s.f.u, &s.f.v, &s.f.w, &s.f.th];
    let stride = [1, k.nxh, k.nxh * k.nyh, 0];
    let mut out = [(0.0f64, 0.0f64); 4];
    let mut n = 0usize;
    for kk in 0..k.nz {
        for j in cr.j0..(cr.j0 + cr.n).min(k.ny) {
            for i in cr.i0..(cr.i0 + cr.n).min(k.nx) {
                let g = ((kk + 1) * k.nyh + j + 1) * k.nxh + i + 1;
                n += 1;
                for f in 0..4 {
                    let at = |a: &[f32]| {
                        if f == 3 {
                            f64::from(a[g])
                        } else {
                            0.5 * (f64::from(a[g]) + f64::from(a[g + stride[f]]))
                        }
                    };
                    let d = (at(mine[f]) - at(refs[f])).abs();
                    out[f].0 = out[f].0.max(d);
                    out[f].1 += d * d;
                }
            }
        }
    }
    for o in &mut out {
        o.1 = (o.1 / n.max(1) as f64).sqrt();
    }
    Ok(Some(out))
}

/// Compares the solved fields with `sol_*` of the case.
/// `None` when the case has no reference.
pub fn deviation(c: &Case, s: &Picard) -> Result<Option<Dev>> {
    let Some(sol) = c.solution.as_ref().filter(|_| c.has_reference()) else {
        return Ok(None);
    };
    let (su, sv, sw) = (c.arr("sol_u")?, c.arr("sol_v")?, c.arr("sol_w")?);
    let u0 = c.case_params.u_aloft.max(sol.max_speed);
    let du = max_abs_diff(&s.f.u, su)
        .max(max_abs_diff(&s.f.v, sv))
        .max(max_abs_diff(&s.f.w, sw));
    Ok(Some(Dev {
        u0,
        u_rel: du / u0,
        th_abs: max_abs_diff(&s.f.th, c.arr("sol_th")?)
            .max(max_abs_diff(&s.f.thd, c.arr("sol_thd")?)),
        p_rel: max_abs_diff(&s.f.p, c.arr("sol_p")?) / max_abs(c.arr("sol_p")?).max(1e-30),
        div_rms: div_rms_f64(s, &s.f.u, &s.f.v, &s.f.w),
        div_rms_ref: div_rms_f64(s, su, sv, sw),
        crop: crop_dev(c, s)?,
    }))
}

/// Text table of the deviation per field (max with its cell, rms, 99.9th percentile) over air cells.
pub fn diag(c: &Case, s: &Picard) -> Result<String> {
    if !c.has_reference() {
        anyhow::bail!("case {} has no reference: no deviation table", c.name);
    }
    let k = &s.k;
    let mut out = String::from("field | max | at (i,j,k) | rms | p99.9\n");
    let fields: [(&str, &[f32], &[f32]); 5] = [
        ("u", &s.f.u, c.arr("sol_u")?),
        ("v", &s.f.v, c.arr("sol_v")?),
        ("w", &s.f.w, c.arr("sol_w")?),
        ("th", &s.f.th, c.arr("sol_th")?),
        ("thd", &s.f.thd, c.arr("sol_thd")?),
    ];
    for (name, a, b) in fields {
        let mut ds: Vec<f64> = Vec::new();
        let (mut best, mut at) = (0.0f64, (0, 0, 0));
        let mut sq = 0.0f64;
        for kk in 0..k.nz {
            for j in 0..k.ny {
                for i in 0..k.nx {
                    let g = ((kk + 1) * k.nyh + j + 1) * k.nxh + i + 1;
                    if k.cell[g] != 1 {
                        continue;
                    }
                    let d = (f64::from(a[g]) - f64::from(b[g])).abs();
                    sq += d * d;
                    ds.push(d);
                    if d > best {
                        best = d;
                        at = (i, j, kk);
                    }
                }
            }
        }
        ds.sort_by(f64::total_cmp);
        let p = ds.get(ds.len() * 999 / 1000).copied().unwrap_or(0.0);
        let rms = (sq / ds.len().max(1) as f64).sqrt();
        out += &format!("{name} | {best:.3e} | {at:?} | {rms:.3e} | {p:.3e}\n");
    }
    Ok(out)
}

fn num(x: f64) -> Value {
    if x.is_finite() { json!(x) } else { Value::Null }
}

/// CPU model name from `/proc/cpuinfo` (null elsewhere).
pub fn cpu_name() -> Value {
    std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|t| {
            t.lines()
                .find(|l| l.starts_with("model name"))
                .and_then(|l| l.split(':').nth(1))
                .map(|s| json!(s.trim()))
        })
        .unwrap_or(Value::Null)
}

/// Short git hash of the working directory (null when unavailable).
pub fn git_hash() -> Value {
    std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| json!(s.trim()))
        .unwrap_or(Value::Null)
}

/// Build profile name for the result file.
pub fn profile() -> &'static str {
    if cfg!(debug_assertions) {
        "dev"
    } else {
        "release"
    }
}

/// Timing summary of a run.
pub struct Timing {
    pub total_s: f64,
    pub setup_s: f64,
    pub iter_s: f64,
    pub iters_run: usize,
    pub check_s: f64,
    pub n_checks: usize,
    /// Threads actually present in the rayon pool.
    pub pool_threads: usize,
    /// CPU seconds (user+system) the process used until the result was built.
    pub cpu_s: f64,
    /// Total seconds per iteration phase `[mom, heat, proj, kupd, other]` (R2 v2 `time.phase_ms`
    /// is the mean per iteration); `None` for a timing-only run.
    pub phase_s: Option<[f64; 5]>,
}

/// What a solve was asked and what it produced beyond R2 v2 (R2 v3 fields).
pub struct RunInfo {
    /// `converged | max_iters | time_budget | diverged`.
    pub stop: &'static str,
    pub tol_scale: f64,
    pub time_budget_s: Option<f64>,
    /// Path of the R4 snapshot the run started from.
    pub init: Option<String>,
    /// Paths of written R4 snapshots.
    pub snapshots: Vec<String>,
    /// Residuals of the delivered field (a history record).
    pub residuals: Check,
}

/// One history record as JSON `{it, t_s, mom_rms, mom_max, th_rms, thd_rms, div_rms}`.
pub fn check_json(h: &Check) -> Value {
    json!({
        "it": h.it, "t_s": num(h.t_s), "mom_rms": num(h.res.mom_rms), "mom_max": num(h.res.mom_max),
        "th_rms": num(h.res.th_rms), "thd_rms": num(h.res.thd_rms), "div_rms": num(h.res.div_rms),
    })
}

/// Builds the R2 document: version 3 with `run`, else 2 with phases, else 1.
#[allow(clippy::too_many_arguments)]
pub fn result_json(
    c: &Case,
    threads: usize,
    status: &str,
    iters: usize,
    history: Value,
    dev: Option<&Dev>,
    t: &Timing,
    run: Option<&RunInfo>,
) -> Value {
    let n_cells = c.n_cells();
    let ms_it = if t.iters_run > 0 {
        t.iter_s / t.iters_run as f64 * 1e3
    } else {
        f64::NAN
    };
    let ck = if t.n_checks > 0 {
        t.check_s / t.n_checks as f64 * 1e3
    } else {
        f64::NAN
    };
    let dev_v = match dev {
        Some(d) => json!({
            "u0": num(d.u0), "u_rel": num(d.u_rel), "th_abs": num(d.th_abs), "p_rel": num(d.p_rel),
            "div_rms": num(d.div_rms), "div_rms_ref": num(d.div_rms_ref),
        }),
        None => json!({
            "u0": null, "u_rel": null, "th_abs": null, "p_rel": null, "div_rms": null, "div_rms_ref": null,
        }),
    };
    let mut time = json!({
            "total_s": num(t.total_s), "setup_s": num(t.setup_s), "ms_per_iter": num(ms_it),
            "check_ms": num(ck), "ns_per_cell_iter": num(ms_it * 1e6 / n_cells as f64),
            "n_cells": n_cells,
            "pool_threads": t.pool_threads, "process_cpu_s": num(t.cpu_s),
    });
    let version = match (run, &t.phase_s) {
        (Some(_), _) => 3,
        (None, Some(_)) => 2,
        (None, None) => 1,
    };
    if let Some(p) = &t.phase_s {
        let n = t.iters_run.max(1) as f64 * 1e-3;
        time["phase_ms"] = json!({
            "mom": num(p[0] / n), "heat": num(p[1] / n), "proj": num(p[2] / n),
            "kupd": num(p[3] / n), "other": num(p[4] / n),
        });
    }
    let mut doc = json!({
        "format": "picard-rs-result",
        "version": version,
        "case": c.name,
        "input": c.path,
        "profile": profile(),
        "threads": threads,
        "dtype": "f32",
        "status": status,
        "iters": iters,
        "iters_ref": c.solution.as_ref().map(|s| s.iters),
        "history": history,
        "history_ref": c.history_ref,
        "dev": dev_v,
        "dev_crop": dev.and_then(|d| d.crop).map_or(Value::Null, |c| json!({
            "u_max": num(c[0].0), "u_rms": num(c[0].1), "v_max": num(c[1].0), "v_rms": num(c[1].1),
            "w_max": num(c[2].0), "w_rms": num(c[2].1), "th_max": num(c[3].0), "th_rms": num(c[3].1),
        })),
        "time": time,
        "host": {"cpu": cpu_name(), "rustc": env!("PICARD_RUSTC_VERSION"), "git": git_hash()},
    });
    if let Some(r) = run {
        doc["stop"] = json!(r.stop);
        doc["tol_scale"] = num(r.tol_scale);
        doc["time_budget_s"] = r.time_budget_s.map_or(Value::Null, num);
        doc["init"] = json!(r.init);
        doc["snapshots"] = json!(r.snapshots);
        doc["residuals"] = check_json(&r.residuals);
    }
    doc
}

/// History of a solve as JSON records (see [`check_json`]).
pub fn history_json(o: &SolveOut) -> Value {
    Value::Array(o.history.iter().map(check_json).collect())
}

/// Writes JSON to a temporary file and renames it.
pub fn write_atomic(path: &Path, v: &Value) -> Result<()> {
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(v)?)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}
