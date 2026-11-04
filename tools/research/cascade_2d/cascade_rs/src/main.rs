//! cascade: stateless cascade of a coarse 2D wind slice (P400/P200) down to 25 m by splitting
//! faces with exact mass balance (research prototype, module cascade-2d).

mod f1;
mod geo;
mod geosrc;
mod level;
mod rules;
mod run;
mod selftest;
mod synth;
#[cfg(test)]
mod tests;
mod util;

use anyhow::{Result, bail};
use clap::{Args, Parser, Subcommand};
use geosrc::GeoSrc;
use rules::Variant;
use std::path::PathBuf;
use std::time::Instant;

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Args)]
struct Common {
    /// Parent field (F1, picard P400 or P200).
    #[arg(long)]
    parent: PathBuf,
    /// Case name (C0..C4).
    #[arg(long)]
    case: String,
    /// Finest cell size, m.
    #[arg(long, default_value_t = 25)]
    to: usize,
    /// V0 | V1 | V2 | V3 | V3h.
    #[arg(long)]
    variant: String,
    /// Hash seed (V3h) and random points (query).
    #[arg(long, default_value_t = 0)]
    seed: u64,
    #[arg(long, default_value_t = 8)]
    threads: usize,
    /// Directory of the F1 files of the levels and of the F2 record.
    #[arg(long)]
    out_dir: PathBuf,
    /// Where the copy of F2 goes (default: tools/research/cascade_2d/out/runs of the repository).
    #[arg(long)]
    runs_dir: Option<PathBuf>,
    /// Geometry of the finer levels: case | synth | synth-heated.
    #[arg(long, default_value = "case")]
    geom: String,
    /// Background Brunt-Vaisala frequency, 1/s (default 0: neutral).
    #[arg(long)]
    n_bg: Option<f64>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Whole-field descent; writes F1 of every level and F2.
    Descend(Common),
    /// Point-by-point descent of random air cells, compared bit for bit with the whole field.
    Query {
        #[command(flatten)]
        c: Common,
        /// Number of random points.
        #[arg(long, default_value_t = 1000)]
        points: usize,
    },
    /// Writes a synthetic divergence-free parent F1 (demonstration and tests).
    SynthParent {
        #[arg(long)]
        case: String,
        #[arg(long, default_value_t = 400)]
        dx: usize,
        #[arg(long, default_value_t = 5.0)]
        u0: f64,
        #[arg(long, default_value_t = 0.0)]
        noise: f64,
        #[arg(long, default_value_t = 1)]
        seed: u64,
        #[arg(long)]
        out: PathBuf,
    },
    /// Balance and path-vs-full on synthetic parents; prints max_rel_div and path_vs_full.
    Selftest,
}

fn opts(c: &Common) -> Result<run::RunOpts> {
    let Some(var) = Variant::parse(&c.variant) else {
        bail!("--variant: V0 | V1 | V2 | V3 | V3h");
    };
    Ok(run::RunOpts {
        parent: c.parent.clone(),
        case: c.case.clone(),
        to: c.to,
        var,
        seed: c.seed,
        threads: c.threads.max(1),
        out_dir: c.out_dir.clone(),
        runs_dir: c.runs_dir.clone(),
        geom: GeoSrc::parse(&c.geom)?,
        n_bg: c.n_bg,
    })
}

fn main() -> Result<()> {
    let t0 = Instant::now();
    let cmdline = std::env::args().collect::<Vec<_>>().join(" ");
    match Cli::parse().cmd {
        Cmd::Descend(c) => {
            let o = opts(&c)?;
            let st = run::setup(&o)?;
            let t = Instant::now();
            let levels = run::descend(&st.ctxs, &st.parent, o.threads)?;
            let work = t.elapsed().as_secs_f64();
            run::write_results(&o, &st, &levels, work, t0, None, &cmdline)?;
        }
        Cmd::Query { c, points } => {
            let o = opts(&c)?;
            let st = run::setup(&o)?;
            let levels = run::descend(&st.ctxs, &st.parent, o.threads)?;
            let q = run::query(&st, levels.last().unwrap(), points, o.seed);
            run::write_results(&o, &st, &levels, 0.0, t0, Some(&q), &cmdline)?;
        }
        Cmd::SynthParent {
            case,
            dx,
            u0,
            noise,
            seed,
            out,
        } => {
            let n = (400 / dx).trailing_zeros() as usize;
            let g = synth::geo(&case, n, true);
            let l = synth::parent(&g, u0, noise, seed);
            let wm = f1::WriteMeta {
                case: &case,
                source: "picard",
                variant: None,
                parent_dx: None,
                seed: None,
                git: Some("synthetic".into()),
            };
            f1::write_f1(&out, &wm, &l, &g)?;
        }
        Cmd::Selftest => {
            let (rel, path) = selftest::run(300);
            println!("max_rel_div={rel:e}");
            println!("path_vs_full={path}");
        }
    }
    Ok(())
}
