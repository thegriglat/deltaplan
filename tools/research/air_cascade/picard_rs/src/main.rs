//! `picard` command line: `blocks`, `solve`, `bench` (see the crate README).

use anyhow::Result;
use clap::{Parser, Subcommand};
use picard_rs::blocks::check_case;
use picard_rs::case::{Case, Consts};
use picard_rs::report::{
    Timing, deviation, diag as diag_table, history_json, profile, result_json, write_atomic,
};
use picard_rs::solver::Picard;
use std::path::{Path, PathBuf};
use std::time::Instant;

#[derive(Parser)]
#[command(about = "Picard iteration of the 3D air model (AM-01), Rust prototype")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Relative errors of the iteration blocks against the blocks of the case files.
    Blocks {
        cases: Vec<PathBuf>,
        #[arg(long, default_value_t = 1)]
        threads: usize,
    },
    /// Solve to the criterion and write the R2 result.
    Solve {
        case: PathBuf,
        #[arg(long, default_value_t = 1)]
        threads: usize,
        #[arg(long, default_value_t = 2000)]
        max_iters: usize,
        #[arg(long)]
        out: Option<PathBuf>,
        /// Multiply the three tolerances of the criterion (diagnostics of the unconverged tail).
        #[arg(long, default_value_t = 1.0)]
        tol_scale: f64,
        /// Print the per-field deviation table (max, its cell, rms, 99.9th percentile).
        #[arg(long)]
        diag: bool,
    },
    /// Time K iterations for each thread count; one R2 file per count.
    Bench {
        case: PathBuf,
        #[arg(long, value_delimiter = ',', default_value = "1")]
        threads: Vec<usize>,
        #[arg(long, default_value_t = 20)]
        iters: usize,
        #[arg(long, default_value = "out")]
        out_dir: PathBuf,
        /// Solve to the criterion instead of timing K iterations (result with deviation).
        #[arg(long)]
        solve: bool,
        #[arg(long, default_value_t = 2000)]
        max_iters: usize,
    },
}

fn pool(n: usize) -> Result<rayon::ThreadPool> {
    Ok(rayon::ThreadPoolBuilder::new()
        .num_threads(n.max(1))
        .build()?)
}

/// User+system CPU seconds of this process (Linux `/proc/self/stat`, 100 ticks/s; 0 elsewhere).
fn cpu_seconds() -> f64 {
    std::fs::read_to_string("/proc/self/stat")
        .ok()
        .and_then(|s| {
            let rest = s.rsplit(')').next()?.to_string();
            let f: Vec<&str> = rest.split_whitespace().collect();
            let (u, k) = (
                f.get(11)?.parse::<f64>().ok()?,
                f.get(12)?.parse::<f64>().ok()?,
            );
            Some((u + k) / 100.0)
        })
        .unwrap_or(0.0)
}

/// Scale the stopping tolerances of the case by `s` (1 = as in the reference).
fn scale_criterion(c: &mut Case, s: f64) {
    c.criterion.tol_mom_rms *= s;
    c.criterion.tol_th_rms *= s;
    c.criterion.tol_div_rms *= s;
}

/// Solve `c` to its criterion on a pool of `threads`, print one line and write the R2 result.
fn solve_case(
    c: &Case,
    threads: usize,
    max_iters: usize,
    out: Option<PathBuf>,
    diag: bool,
) -> Result<()> {
    let t0 = Instant::now();
    let pl = pool(threads)?;
    let (o, dev, setup_s, dtab) = pl.install(|| -> Result<_> {
        let mut s = Picard::new(Consts::from_case(c)?);
        s.init_background();
        let setup_s = t0.elapsed().as_secs_f64();
        let o = s.solve(&c.criterion, max_iters);
        s.finalize(10);
        let dev = deviation(c, &s)?;
        let dtab = if diag {
            diag_table(c, &s)?
        } else {
            String::new()
        };
        Ok((o, dev, setup_s, dtab))
    })?;
    let t = Timing {
        total_s: t0.elapsed().as_secs_f64(),
        setup_s,
        iter_s: o.iter_s,
        iters_run: o.iters,
        check_s: o.check_s,
        n_checks: o.n_checks,
        pool_threads: pl.current_num_threads(),
        cpu_s: cpu_seconds(),
    };
    let doc = result_json(
        c,
        threads,
        o.status,
        o.iters,
        history_json(&o),
        Some(&dev),
        &t,
    );
    let path = out.unwrap_or_else(|| {
        PathBuf::from(format!("out/{}_{}_t{}.json", c.name, profile(), threads))
    });
    write_atomic(&path, &doc)?;
    print!("{dtab}");
    println!(
        "pool threads {} (requested {threads}), process cpu {:.1} s, wall {:.1} s",
        pl.current_num_threads(),
        cpu_seconds(),
        t.total_s
    );
    println!(
        "{}: status {} iters {}/{} u_rel {:.3e} th_abs {:.3e} K ms/iter {:.3} -> {}",
        c.name,
        o.status,
        o.iters,
        c.solution.iters,
        dev.u_rel,
        dev.th_abs,
        t.iter_s / t.iters_run.max(1) as f64 * 1e3,
        path.display()
    );
    Ok(())
}

fn main() -> Result<()> {
    match Cli::parse().cmd {
        Cmd::Blocks { cases, threads } => {
            let pl = pool(threads)?;
            let mut worst = 0.0f64;
            println!("case | block | rel");
            for p in &cases {
                let c = Case::load(p)?;
                let rows = pl.install(|| check_case(&c))?;
                for r in &rows {
                    println!(
                        "{} | {} | {:e}{}",
                        c.name,
                        r.name,
                        r.rel,
                        if r.checked { "" } else { " (info)" }
                    );
                    if r.checked {
                        worst = if r.rel.is_nan() {
                            f64::NAN
                        } else {
                            worst.max(r.rel)
                        };
                    }
                }
            }
            println!("max_block_rel={worst:e}");
        }
        Cmd::Solve {
            case,
            threads,
            max_iters,
            out,
            tol_scale,
            diag,
        } => {
            let mut c = Case::load(&case)?;
            scale_criterion(&mut c, tol_scale);
            solve_case(&c, threads, max_iters, out, diag)?;
        }
        Cmd::Bench {
            case,
            threads,
            iters,
            out_dir,
            solve,
            max_iters,
        } => {
            let c = Case::load(&case)?;
            for &n in &threads {
                if solve {
                    let path = out_dir.join(format!("{}_{}_t{}.json", c.name, profile(), n));
                    solve_case(&c, n, max_iters, Some(path), false)?;
                    continue;
                }
                let pl = pool(n)?;
                let t0 = Instant::now();
                let (setup_s, iter_s, check_s) = pl.install(|| -> Result<_> {
                    let mut s = Picard::new(Consts::from_case(&c)?);
                    s.init_background();
                    let setup_s = t0.elapsed().as_secs_f64();
                    for _ in 0..2 {
                        s.outer_step();
                    }
                    let t1 = Instant::now();
                    for _ in 0..iters {
                        s.outer_step();
                    }
                    let iter_s = t1.elapsed().as_secs_f64();
                    let t2 = Instant::now();
                    let _ = s.residuals();
                    Ok((setup_s, iter_s, t2.elapsed().as_secs_f64()))
                })?;
                let t = Timing {
                    total_s: t0.elapsed().as_secs_f64(),
                    setup_s,
                    iter_s,
                    iters_run: iters,
                    check_s,
                    n_checks: 1,
                    pool_threads: pl.current_num_threads(),
                    cpu_s: cpu_seconds(),
                };
                let doc = result_json(&c, n, "max", iters, serde_json::json!([]), None, &t);
                let path: PathBuf = out_dir.join(format!("{}_{}_t{}.json", c.name, profile(), n));
                write_atomic(Path::new(&path), &doc)?;
                println!(
                    "{} threads {n}: {:.3} ms/iter",
                    c.name,
                    iter_s / iters as f64 * 1e3
                );
            }
        }
    }
    Ok(())
}
