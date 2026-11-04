//! Where the geometry of the finer levels comes from: R1 case files (middle row) or synthetic.

use crate::geo::Geo;
use crate::rules::Cfg;
use crate::util::data_dir;
use anyhow::{Result, bail};
use picard_rs::case::Case;
use std::path::PathBuf;

#[derive(Clone)]
pub enum GeoSrc {
    /// `$CASCADE2D_DATA/cases/<C>_d<dx>.json` (R1, F0).
    Case(PathBuf),
    /// Built-in Agnesi hill, optionally with a heat source.
    Synth { heated: bool },
}

impl GeoSrc {
    pub fn parse(s: &str) -> Result<GeoSrc> {
        Ok(match s {
            "case" => GeoSrc::Case(data_dir().join("cases")),
            "synth" => GeoSrc::Synth { heated: false },
            "synth-heated" => GeoSrc::Synth { heated: true },
            _ => bail!("--geom: case | synth | synth-heated"),
        })
    }

    /// Geometry of `case` at `dx`, cropped to `nz` rows, and the model constants of the case file.
    pub fn load(&self, case: &str, dx: usize, nz: usize) -> Result<(Geo, Option<(f64, f64)>)> {
        match self {
            GeoSrc::Synth { heated } => {
                let n = (400 / dx).trailing_zeros() as usize;
                let mut g = crate::synth::geo(case, n, *heated);
                g.crop_rows(nz)?;
                Ok((g, None))
            }
            GeoSrc::Case(dir) => {
                let c = Case::load(&dir.join(format!("{case}_d{dx}.json")))?;
                if c.dx as usize != dx || c.nx * dx != 12800 {
                    bail!(
                        "case {case} d{dx}: dx={} nx={}, expected the F0 grid",
                        c.dx,
                        c.nx
                    );
                }
                let (nxh, nyh) = (c.nxh, c.nyh);
                let jh = c.ny / 2 + 1;
                let a = |n: &str| c.arr(n).cloned();
                let (cell, tu, tw, q, hc) = (a("cell")?, a("tu")?, a("tw")?, a("Q")?, a("hc")?);
                let at = |v: &Vec<f32>, k: usize, i: usize| v[(k * nyh + jh) * nxh + i];
                let (nx, nzc) = (c.nx, c.nz);
                let mut g = Geo {
                    nx,
                    nz: nzc,
                    dx: c.dx as f64,
                    dz: c.dz as f64,
                    z0: c.z_bot as f64,
                    cell: vec![0; nzc * nx],
                    tu: vec![0; nzc * (nx + 1)],
                    tw: vec![0; (nzc + 1) * nx],
                    h: (0..nx).map(|i| hc[(c.ny / 2) * nx + i]).collect(),
                    q: vec![0.0; nzc * nx],
                };
                for k in 0..nzc {
                    for i in 0..nx {
                        g.cell[k * nx + i] = u8::from(at(&cell, k + 1, i + 1) > 0.5);
                        g.q[k * nx + i] = at(&q, k + 1, i + 1);
                    }
                    for i in 0..=nx {
                        g.tu[k * (nx + 1) + i] = at(&tu, k + 1, i + 1) as u8;
                    }
                }
                for k in 0..=nzc {
                    for i in 0..nx {
                        g.tw[k * nx + i] = at(&tw, k + 1, i + 1) as u8;
                    }
                }
                g.crop_rows(nz)?;
                Ok((g, Some((c.params.tau_cool, c.params.z0))))
            }
        }
    }
}

/// Constants of the rules from the finest case file (or defaults).
pub fn cfg_from(consts: Option<(f64, f64)>, n_bg: Option<f64>) -> Cfg {
    let mut c = Cfg::default();
    if let Some((tau, z0)) = consts {
        c.tau_cool = tau;
        c.z0 = z0;
    }
    if let Some(n) = n_bg {
        c.n_bg = n;
    }
    c
}
