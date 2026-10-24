//! `picard` command line: `blocks`, `solve`, `bench` (see the crate README).

use anyhow::Result;
use clap::{Parser, Subcommand};
use picard_rs::api::{self, SolveOpts};
use picard_rs::blocks::check_case;
use picard_rs::case::{Case, Consts};
use picard_rs::report::{
    RunInfo, Timing, diag as diag_table, history_json, profile, result_json, write_atomic,
};
use picard_rs::solver::Picard;
use picard_rs::state::State;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

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
        /// Multiply the three tolerances of the criterion (1 = as the reference).
        #[arg(long, default_value_t = 1.0)]
        tol_scale: f64,
        /// Print the per-field deviation table (max, its cell, rms, 99.9th percentile).
        #[arg(long)]
        diag: bool,
        /// Stop after the iteration at which this many wall seconds of iterating are used.
        #[arg(long)]
        time_budget: Option<f64>,
        /// Warm start from an R4 snapshot (`.json`).
        #[arg(long)]
        init: Option<PathBuf>,
        /// Iterations after which to snapshot (comma separated, ascending); needs `--snap-dir`.
        #[arg(long, value_delimiter = ',')]
        snap_at: Vec<usize>,
        /// Directory for the snapshots `<case>_it<N>.json`.
        #[arg(long)]
        snap_dir: Option<PathBuf>,
        /// Write the delivered field as an R4 snapshot.
        #[arg(long)]
        save_state: Option<PathBuf>,
    },
    /// Print the code branch (multiversion dispatch) selected on this CPU.
    Isa,
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

/// Command line options of `solve` beyond the case, threads and output.
struct SolveArgs {
    max_iters: usize,
    tol_scale: f64,
    time_budget: Option<f64>,
    init: Option<PathBuf>,
    snap_at: Vec<usize>,
    snap_dir: Option<PathBuf>,
    save_state: Option<PathBuf>,
    diag: bool,
}

/// Solve `c` to its criterion on a pool of `threads`, print one line and write the R2 result.
fn solve_case(c: &Case, threads: usize, out: Option<PathBuf>, a: &SolveArgs) -> Result<()> {
    let threads = api::resolve_threads(threads);
    if !a.snap_at.is_empty() && a.snap_dir.is_none() {
        anyhow::bail!("--snap-at needs --snap-dir");
    }
    let r = api::solve(
        c,
        &SolveOpts {
            threads,
            max_iters: a.max_iters,
            tol_scale: a.tol_scale,
            time_budget: a.time_budget.map(Duration::from_secs_f64),
            init: a.init.as_deref().map(State::read).transpose()?,
            snapshot_at: a.snap_at.clone(),
        },
    )?;
    let (o, dev, t) = (&r.out, &r.dev, &r.timing);
    let mut snap_paths = Vec::new();
    if let Some(dir) = &a.snap_dir {
        for s in &r.snapshots {
            let p = dir.join(format!("{}_it{}.json", c.name, s.it));
            s.write_atomic(&p)?;
            snap_paths.push(p.display().to_string());
        }
    }
    if let Some(p) = &a.save_state {
        r.state.write_atomic(p)?;
    }
    let dtab = if a.diag {
        r.pool.install(|| diag_table(c, &r.picard))?
    } else {
        String::new()
    };
    let info = RunInfo {
        stop: r.stop.as_str(),
        tol_scale: a.tol_scale,
        time_budget_s: a.time_budget,
        init: a.init.as_ref().map(|p| p.display().to_string()),
        snapshots: snap_paths,
        residuals: *r.history.last().expect("history ends with a check"),
    };
    let doc = result_json(
        c,
        threads,
        o.status,
        o.iters,
        history_json(o),
        Some(dev),
        t,
        Some(&info),
    );
    let path = out.unwrap_or_else(|| {
        PathBuf::from(format!("out/{}_{}_t{}.json", c.name, profile(), threads))
    });
    write_atomic(&path, &doc)?;
    print!("{dtab}");
    println!(
        "pool threads {} (requested {threads}), process cpu {:.1} s, wall {:.1} s",
        t.pool_threads,
        api::cpu_seconds(),
        t.total_s
    );
    println!(
        "{}: status {} stop {} iters {}/{} u_rel {:.3e} th_abs {:.3e} K ms/iter {:.3} -> {}",
        c.name,
        o.status,
        r.stop.as_str(),
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
        Cmd::Isa => println!("isa_branch={}", picard_rs::util::isa_branch()),
        Cmd::Blocks { cases, threads } => {
            let pl = api::pool(threads)?;
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
            time_budget,
            init,
            snap_at,
            snap_dir,
            save_state,
        } => {
            let c = Case::load(&case)?;
            let a = SolveArgs {
                max_iters,
                tol_scale,
                time_budget,
                init,
                snap_at,
                snap_dir,
                save_state,
                diag,
            };
            solve_case(&c, threads, out, &a)?;
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
                let n = api::resolve_threads(n);
                if solve {
                    let path = out_dir.join(format!("{}_{}_t{}.json", c.name, profile(), n));
                    let a = SolveArgs {
                        max_iters,
                        tol_scale: 1.0,
                        time_budget: None,
                        init: None,
                        snap_at: Vec::new(),
                        snap_dir: None,
                        save_state: None,
                        diag: false,
                    };
                    solve_case(&c, n, Some(path), &a)?;
                    continue;
                }
                let pl = api::pool(n)?;
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
                    cpu_s: api::cpu_seconds(),
                    phase_s: None,
                };
                let doc = result_json(&c, n, "max", iters, serde_json::json!([]), None, &t, None);
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
