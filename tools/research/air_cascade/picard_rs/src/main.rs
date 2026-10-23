//! `picard` command line: `blocks`, `solve`, `bench` (see the crate README).

use anyhow::Result;
use clap::{Parser, Subcommand};
use picard_rs::blocks::check_case;
use picard_rs::case::{Case, Consts};
use picard_rs::report::{Timing, deviation, history_json, profile, result_json, write_atomic};
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
    },
}

fn pool(n: usize) -> Result<rayon::ThreadPool> {
    Ok(rayon::ThreadPoolBuilder::new()
        .num_threads(n.max(1))
        .build()?)
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
        } => {
            let t0 = Instant::now();
            let c = Case::load(&case)?;
            let pl = pool(threads)?;
            let (o, dev, setup_s) = pl.install(|| -> Result<_> {
                let mut s = Picard::new(Consts::from_case(&c)?);
                s.init_background();
                let setup_s = t0.elapsed().as_secs_f64();
                let o = s.solve(&c.criterion, max_iters);
                s.finalize(10);
                let dev = deviation(&c, &s)?;
                Ok((o, dev, setup_s))
            })?;
            let t = Timing {
                total_s: t0.elapsed().as_secs_f64(),
                setup_s,
                iter_s: o.iter_s,
                iters_run: o.iters,
                check_s: o.check_s,
                n_checks: o.n_checks,
            };
            let doc = result_json(
                &c,
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
        }
        Cmd::Bench {
            case,
            threads,
            iters,
            out_dir,
        } => {
            let c = Case::load(&case)?;
            for &n in &threads {
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
