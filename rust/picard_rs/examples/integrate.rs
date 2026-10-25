//! Minimal integration example: load an R1 case, solve on 2 threads with `tol_scale` 5,
//! print the stop reason and the reached residuals, take the fields for a warm start.
//! Usage: integrate <case.json>

use picard_rs::api::{SolveOpts, solve};
use picard_rs::case::Case;
use std::path::Path;

fn main() -> anyhow::Result<()> {
    let path = std::env::args()
        .nth(1)
        .expect("usage: integrate <case.json>");
    // Reads <case>.json and the <case>.bin next to it (R1 format).
    let case = Case::load(Path::new(&path))?;

    // Cold start: private pool of 2 threads, the global rayon pool is not touched.
    let opts = SolveOpts {
        threads: 2,
        tol_scale: 5.0,
        ..Default::default()
    };
    let r = solve(&case, &opts)?;
    println!(
        "stop={} iters={} mom_rms={:.3e} th_rms={:.3e} div_rms={:.3e} total_s={:.2}",
        r.stop.as_str(),
        r.iters,
        r.residuals.mom_rms,
        r.residuals.th_rms,
        r.residuals.div_rms,
        r.timing.total_s
    );

    // Fields with halo, layout (NZ, NY, NX), index (k * NY + j) * NX + i, f32.
    let s = &r.state;
    println!(
        "dims_halo={:?} cells={} u[0]={} w[0]={}",
        s.dims,
        s.n3(),
        s.u[0],
        s.w[0]
    );

    // Warm start of a later call on the same grid: pass the previous state as `init`.
    let warm = SolveOpts {
        threads: 2,
        tol_scale: 5.0,
        init: Some(r.state),
        ..Default::default()
    };
    let r2 = solve(&case, &warm)?;
    println!("warm stop={} iters={}", r2.stop.as_str(), r2.iters);
    Ok(())
}
