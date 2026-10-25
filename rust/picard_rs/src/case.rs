//! Reading an R1 case (`<case>.json` + `<case>.bin`) and the constant per-case input.

use anyhow::{Context, Result, anyhow, bail};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::Path;

/// Model parameters taken from the case file (never from solver defaults).
#[derive(Debug, Clone, Deserialize)]
pub struct Params {
    pub tau_cool: f64,
    pub z0: f64,
    pub pr_t: f64,
    pub dtau_u: Option<f64>,
    pub dtau_per_m: f64,
    pub dtau_th: f64,
    pub couple: f64,
    pub mom_sweeps: usize,
    pub heat_sweeps: usize,
    pub vcycles: usize,
    pub local_k: bool,
    pub k_relax: f64,
    pub cs_h: f64,
}

/// Case conditions needed beyond the arrays.
#[derive(Debug, Clone, Deserialize)]
pub struct CaseParams {
    #[serde(rename = "U10")]
    pub u10: f64,
    #[serde(rename = "U_aloft")]
    pub u_aloft: f64,
}

/// Stopping criterion of the reference.
#[derive(Debug, Clone, Deserialize)]
pub struct Criterion {
    pub tol_mom_rms: f64,
    pub tol_th_rms: f64,
    pub tol_div_rms: f64,
    pub check_every: usize,
    /// Steps done before the first block of `check_every` (reference graph capture runs one step
    /// and counts it); derived from `history[0].it`, not read from the file.
    #[serde(default)]
    pub pre_steps: usize,
}

/// Reference solution summary.
#[derive(Debug, Clone, Deserialize)]
pub struct SolutionRef {
    pub iters: usize,
    pub max_speed: f64,
}

/// Reference arrays; all optional (a case without them is solved without a deviation).
pub const REF_ARRAYS: [&str; 6] = ["sol_u", "sol_v", "sol_w", "sol_th", "sol_thd", "sol_p"];

/// Window of cells near the launch site (interior indices), as in the case file.
#[derive(Debug, Clone, Copy, Deserialize)]
pub struct Crop {
    pub i0: usize,
    pub j0: usize,
    pub n: usize,
}

#[derive(Deserialize)]
struct Meta {
    case: String,
    dims: [usize; 3],
    dx: f64,
    dz: f64,
    z_bot: f64,
    nx: usize,
    ny: usize,
    nz: usize,
    params: Params,
    case_params: CaseParams,
    criterion: Criterion,
    #[serde(default)]
    solution: Option<SolutionRef>,
    #[serde(default)]
    history: Option<serde_json::Value>,
    #[serde(default)]
    crop: Option<Crop>,
    arrays: HashMap<String, [usize; 2]>,
}

/// A loaded case: metadata, all arrays of the `.bin` and derived constants.
pub struct Case {
    pub name: String,
    pub path: String,
    /// Dimensions with halo (NX, NY, NZ).
    pub nxh: usize,
    pub nyh: usize,
    pub nzh: usize,
    /// Dimensions without halo.
    pub nx: usize,
    pub ny: usize,
    pub nz: usize,
    pub dx: f32,
    pub dz: f32,
    pub z_bot: f32,
    pub params: Params,
    pub case_params: CaseParams,
    pub criterion: Criterion,
    /// Reference summary; `None` for a case without a reference (the game's input).
    pub solution: Option<SolutionRef>,
    /// Reference residual history; `None` without a reference.
    pub history_ref: Option<serde_json::Value>,
    /// Start-site window (Ongudai cases), if present.
    pub crop: Option<Crop>,
    /// Pseudo-time step of momentum, s.
    pub dtau_u: f32,
    /// Drag coefficient of the first face above ground.
    pub cd: f32,
    pub arrays: HashMap<String, Vec<f32>>,
}

impl Case {
    /// Loads `<path>` (`.json`) and the `.bin` next to it.
    pub fn load(path: &Path) -> Result<Self> {
        let txt = std::fs::read_to_string(path).with_context(|| format!("read {path:?}"))?;
        let m: Meta = serde_json::from_str(&txt).with_context(|| format!("parse {path:?}"))?;
        let bin = std::fs::read(path.with_extension("bin"))
            .with_context(|| format!("read .bin of {path:?}"))?;
        let nf = bin.len() / 4;
        let mut arrays = HashMap::new();
        for (name, [off, len]) in &m.arrays {
            if off + len > nf {
                bail!("array {name} [{off}, {len}] beyond .bin ({nf} f32)");
            }
            let v: Vec<f32> = bin[off * 4..(off + len) * 4]
                .chunks_exact(4)
                .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                .collect();
            arrays.insert(name.clone(), v);
        }
        let p = &m.params;
        let dtau_u = p.dtau_u.unwrap_or(p.dtau_per_m * m.dx);
        let kappa = 0.4_f64;
        let cd = (kappa / (0.5 * m.dz / p.z0).ln()).powi(2);
        let (nxh, nyh, nzh) = (m.dims[0], m.dims[1], m.dims[2]);
        if nxh != m.nx + 2 || nyh != m.ny + 2 || nzh != m.nz + 2 {
            bail!("dims {:?} do not match nx/ny/nz with halo 1", m.dims);
        }
        let case = Self {
            name: m.case,
            path: path.to_string_lossy().into_owned(),
            nxh,
            nyh,
            nzh,
            nx: m.nx,
            ny: m.ny,
            nz: m.nz,
            dx: m.dx as f32,
            dz: m.dz as f32,
            z_bot: m.z_bot as f32,
            params: m.params,
            case_params: m.case_params,
            criterion: Criterion {
                pre_steps: m
                    .history
                    .as_ref()
                    .and_then(|h| h.pointer("/0/it"))
                    .and_then(serde_json::Value::as_u64)
                    .map_or(m.criterion.pre_steps, |v| {
                        v as usize % m.criterion.check_every
                    }),
                ..m.criterion
            },
            solution: m.solution,
            history_ref: m.history,
            crop: m.crop,
            dtau_u: dtau_u as f32,
            cd: cd as f32,
            arrays,
        };
        let n3 = case.n3();
        for a in [
            "cell", "tu", "tv", "tw", "nu_bg", "Q", "sp_u", "sp_w", "spc", "ubg", "vbg",
        ] {
            if case.arr(a)?.len() != n3 {
                bail!("array {a}: length != NX*NY*NZ");
            }
        }
        Ok(case)
    }

    /// Number of cells with halo.
    pub fn n3(&self) -> usize {
        self.nxh * self.nyh * self.nzh
    }

    /// True when the case carries a reference: `solution` and all of `sol_u … sol_p`.
    pub fn has_reference(&self) -> bool {
        self.solution.is_some() && REF_ARRAYS.iter().all(|a| self.arrays.contains_key(*a))
    }

    /// Number of cells without halo.
    pub fn n_cells(&self) -> usize {
        self.nx * self.ny * self.nz
    }

    /// Array by name or an error.
    pub fn arr(&self, name: &str) -> Result<&Vec<f32>> {
        self.arrays
            .get(name)
            .ok_or_else(|| anyhow!("no array '{name}'"))
    }

    /// Array converted to bytes (cell and face types are stored as `f32`).
    pub fn bytes(&self, name: &str) -> Result<Vec<u8>> {
        Ok(self.arr(name)?.iter().map(|&x| x as u8).collect())
    }
}

/// Constant input of the iteration (the "permanent input" of R1).
pub struct Consts {
    pub nxh: usize,
    pub nyh: usize,
    pub nzh: usize,
    pub nx: usize,
    pub ny: usize,
    pub nz: usize,
    pub dx: f32,
    pub dz: f32,
    pub z_bot: f32,
    pub dtau_u: f32,
    pub dtau_th: f32,
    pub inv_tau: f32,
    pub inv_prt: f32,
    pub cd: f32,
    pub u10_positive: bool,
    pub cell: Vec<u8>,
    pub tu: Vec<u8>,
    pub tv: Vec<u8>,
    pub tw: Vec<u8>,
    /// 1.0 in air cells (type 1), else 0.0.
    pub fluid: Vec<f32>,
    pub mu: [Vec<f32>; 3],
    pub sp_u: Vec<f32>,
    pub sp_w: Vec<f32>,
    pub spc: Vec<f32>,
    pub ubg: Vec<f32>,
    pub vbg: Vec<f32>,
    pub q: Vec<f32>,
    pub gam: Vec<f32>,
    pub cplz: Vec<f32>,
    /// Terrain with halo (NY*NX).
    pub hcp: Vec<f32>,
    pub lam: Vec<f32>,
    pub nu_bg: Vec<f32>,
    pub kx: Vec<f32>,
    pub ky: Vec<f32>,
    pub kz: Vec<f32>,
    pub fixed_u: Vec<f32>,
    pub fixed_v: Vec<f32>,
    pub b_u: Vec<usize>,
    pub b_v: Vec<usize>,
    pub n_fluid: f64,
    /// True when `Q` is zero everywhere: the theta'_d step is skipped (it is exactly 0).
    pub no_thd: bool,
    pub mom_sweeps: usize,
    pub heat_sweeps: usize,
    pub vcycles: usize,
    pub local_k: bool,
    pub k_relax: f32,
    pub csdx2: f32,
}

impl Consts {
    /// Builds the constants from a loaded case.
    pub fn from_case(c: &Case) -> Result<Self> {
        let (nxh, nyh) = (c.nxh, c.nyh);
        let cell = c.bytes("cell")?;
        let tu = c.bytes("tu")?;
        let tv = c.bytes("tv")?;
        let tw = c.bytes("tw")?;
        let mask = |t: &[u8]| t.iter().map(|&x| f32::from(x == 1)).collect::<Vec<f32>>();
        let fluid = mask(&cell);
        let hc = c.arr("hc")?;
        let mut hcp = vec![0.0f32; nxh * nyh];
        for j in 0..nyh {
            for i in 0..nxh {
                let jj = j.saturating_sub(1).min(c.ny - 1);
                let ii = i.saturating_sub(1).min(c.nx - 1);
                hcp[j * nxh + i] = hc[jj * c.nx + ii];
            }
        }
        let q = c.arr("Q")?.clone();
        let p = &c.params;
        Ok(Self {
            nxh,
            nyh,
            nzh: c.nzh,
            nx: c.nx,
            ny: c.ny,
            nz: c.nz,
            dx: c.dx,
            dz: c.dz,
            z_bot: c.z_bot,
            dtau_u: c.dtau_u,
            dtau_th: p.dtau_th as f32,
            inv_tau: (1.0 / p.tau_cool) as f32,
            inv_prt: (1.0 / p.pr_t) as f32,
            cd: c.cd,
            u10_positive: c.case_params.u10 > 0.0,
            n_fluid: fluid.iter().map(|&x| f64::from(x)).sum(),
            mu: [mask(&tu), mask(&tv), mask(&tw)],
            cell,
            tu,
            tv,
            tw,
            fluid,
            sp_u: c.arr("sp_u")?.clone(),
            sp_w: c.arr("sp_w")?.clone(),
            spc: c.arr("spc")?.clone(),
            ubg: c.arr("ubg")?.clone(),
            vbg: c.arr("vbg")?.clone(),
            no_thd: q.iter().all(|&x| x == 0.0),
            q,
            gam: c.arr("gam")?.clone(),
            cplz: c.arr("cplz")?.clone(),
            hcp,
            lam: c.arr("lam")?.clone(),
            nu_bg: c.arr("nu_bg")?.clone(),
            kx: c.arr("Kx")?.clone(),
            ky: c.arr("Ky")?.clone(),
            kz: c.arr("Kz")?.clone(),
            fixed_u: c.arr("fixed_u")?.clone(),
            fixed_v: c.arr("fixed_v")?.clone(),
            b_u: c.arr("b_u")?.iter().map(|&x| x as usize).collect(),
            b_v: c.arr("b_v")?.iter().map(|&x| x as usize).collect(),
            mom_sweeps: p.mom_sweeps,
            heat_sweeps: p.heat_sweeps,
            vcycles: p.vcycles,
            local_k: p.local_k,
            k_relax: p.k_relax as f32,
            csdx2: ((p.cs_h * f64::from(c.dx)) * (p.cs_h * f64::from(c.dx))) as f32,
        })
    }

    /// Cells with halo.
    pub fn n3(&self) -> usize {
        self.nxh * self.nyh * self.nzh
    }
}
