//! Result file R2 (`picard-rs-result`, version 1) and the deviation against the reference
//! solution `sol_*` of the case.

use crate::case::Case;
use crate::solver::{Picard, SolveOut};
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

/// Compares the solved fields with `sol_*` of the case.
pub fn deviation(c: &Case, s: &Picard) -> Result<Dev> {
    let (su, sv, sw) = (c.arr("sol_u")?, c.arr("sol_v")?, c.arr("sol_w")?);
    let u0 = c.case_params.u_aloft.max(c.solution.max_speed);
    let du = max_abs_diff(&s.f.u, su)
        .max(max_abs_diff(&s.f.v, sv))
        .max(max_abs_diff(&s.f.w, sw));
    Ok(Dev {
        u0,
        u_rel: du / u0,
        th_abs: max_abs_diff(&s.f.th, c.arr("sol_th")?)
            .max(max_abs_diff(&s.f.thd, c.arr("sol_thd")?)),
        p_rel: max_abs_diff(&s.f.p, c.arr("sol_p")?) / max_abs(c.arr("sol_p")?).max(1e-30),
        div_rms: div_rms_f64(s, &s.f.u, &s.f.v, &s.f.w),
        div_rms_ref: div_rms_f64(s, su, sv, sw),
    })
}

/// Text table of the deviation per field (max with its cell, rms, 99.9th percentile) over air cells.
pub fn diag(c: &Case, s: &Picard) -> Result<String> {
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
}

/// Builds the R2 document.
pub fn result_json(
    c: &Case,
    threads: usize,
    status: &str,
    iters: usize,
    history: Value,
    dev: Option<&Dev>,
    t: &Timing,
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
    json!({
        "format": "picard-rs-result",
        "version": 1,
        "case": c.name,
        "input": c.path,
        "profile": profile(),
        "threads": threads,
        "dtype": "f32",
        "status": status,
        "iters": iters,
        "iters_ref": c.solution.iters,
        "history": history,
        "history_ref": c.history_ref,
        "dev": dev_v,
        "time": {
            "total_s": num(t.total_s), "setup_s": num(t.setup_s), "ms_per_iter": num(ms_it),
            "check_ms": num(ck), "ns_per_cell_iter": num(ms_it * 1e6 / n_cells as f64),
            "n_cells": n_cells,
        },
        "host": {"cpu": cpu_name(), "rustc": env!("PICARD_RUSTC_VERSION"), "git": git_hash()},
    })
}

/// History of a solve as JSON records `{it, mom_rms, mom_max, th_rms, thd_rms, div_rms}`.
pub fn history_json(o: &SolveOut) -> Value {
    Value::Array(
        o.history
            .iter()
            .map(|h| {
                json!({
                    "it": h.it, "mom_rms": num(h.res.mom_rms), "mom_max": num(h.res.mom_max),
                    "th_rms": num(h.res.th_rms), "thd_rms": num(h.res.thd_rms), "div_rms": num(h.res.div_rms),
                })
            })
            .collect(),
    )
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
