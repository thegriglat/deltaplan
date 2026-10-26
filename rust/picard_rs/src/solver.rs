//! The Picard iteration state and driver: outer step, projection, residuals, stopping
//! criterion, finalize — reference `Air.outer_step`, `project`, `residuals`, `solve`,
//! `finalize` (`air.py`) with the second-order advection correction off.

use crate::api::{Fallback, FrozenField};
use crate::case::{Consts, Criterion};
use crate::kernels::{HeatIn, MomIn, Vel, apply_bc, build_all_mom, build_heat, kloc};
use crate::lines::{RowBuf, Scratch, resid, sweep};
use crate::mg::Mg;
use crate::state::State;
use crate::util::{Row, det_sum, par_max};
use anyhow::Result;
use rayon::prelude::*;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// Prognostic fields (halo arrays) and the two eddy viscosities.
#[derive(Clone)]
pub struct Fields {
    pub u: Vec<f32>,
    pub v: Vec<f32>,
    pub w: Vec<f32>,
    pub th: Vec<f32>,
    pub thd: Vec<f32>,
    pub p: Vec<f32>,
    pub nu: Vec<f32>,
    pub nuh: Vec<f32>,
}

/// Residual norms of the steady equations and of the divergence.
#[derive(Debug, Clone, Copy)]
pub struct Residuals {
    pub mom_max: f64,
    pub mom_rms: f64,
    pub th_max: f64,
    pub th_rms: f64,
    pub thd_rms: f64,
    pub div_rms: f64,
}

/// One history record (a residual check).
#[derive(Debug, Clone, Copy)]
pub struct Check {
    pub it: usize,
    pub res: Residuals,
    /// Wall seconds from the start of the iterations to the end of this check (checks included).
    pub t_s: f64,
}

/// Why [`Picard::solve`] stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopReason {
    /// The criterion (tolerances scaled by `tol_scale`) is met.
    Converged,
    /// The iteration limit was reached.
    MaxIters,
    /// The time budget was exhausted after an iteration.
    TimeBudget,
    /// Non-finite residuals or momentum residual above 50.
    Diverged,
    /// W11: every column is frozen, nothing to solve (`iters = 0`).
    AllFrozen,
    /// W11: the cancel flag was set; the current field is delivered.
    Cancelled,
}

impl StopReason {
    /// Name in the R2 `stop` field.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Converged => "converged",
            Self::MaxIters => "max_iters",
            Self::TimeBudget => "time_budget",
            Self::Diverged => "diverged",
            Self::AllFrozen => "all_frozen",
            Self::Cancelled => "cancelled",
        }
    }

    /// Legacy R2 `status`: `ok` | `max` | `diverged`.
    pub fn status(self) -> &'static str {
        match self {
            Self::Converged | Self::AllFrozen => "ok",
            Self::MaxIters | Self::TimeBudget | Self::Cancelled => "max",
            Self::Diverged => "diverged",
        }
    }
}

/// Limits of one [`Picard::solve`] run.
#[derive(Debug, Clone, Copy)]
pub struct RunLimits<'a> {
    /// Stop after exactly this many iterations.
    pub max_iters: usize,
    /// Wall seconds since the start of the iterations; checked after every iteration.
    pub time_budget: Option<Duration>,
    /// Strictly ascending iteration numbers after which a finalized snapshot is taken.
    pub snapshot_at: &'a [usize],
}

/// A finalized copy of the fields taken after `it` iterations.
pub struct RawSnapshot {
    pub it: usize,
    pub f: Fields,
    /// The residual check of iteration `it`, if there was one.
    pub res: Option<Check>,
}

/// Outcome of [`Picard::solve`].
pub struct SolveOut {
    /// `"ok"`, `"max"` or `"diverged"` (R2 `status`).
    pub status: &'static str,
    /// Why the run stopped.
    pub stop: StopReason,
    /// Iterations done.
    pub iters: usize,
    /// Residual checks; the last one is at `iters` (an extra check is made if needed).
    pub history: Vec<Check>,
    /// Seconds spent in iterations (checks and snapshots excluded) and in checks.
    pub iter_s: f64,
    pub check_s: f64,
    pub n_checks: usize,
    /// Total seconds per phase of the iteration (checks excluded), order
    /// `[mom, heat, proj, kupd, other]`; sums to `iter_s`.
    pub phase_s: [f64; 5],
    /// Snapshots requested by `snapshot_at` and reached.
    pub snapshots: Vec<RawSnapshot>,
    /// W11 v3: the omega rollback switched on during the run.
    pub omega_fallback_used: bool,
    /// W11 v3: the run hit `max_iters` unconverged and the field was replaced by `late_mean`.
    pub nonconv_fallback: bool,
    /// W11 v3: fraction of the `nonconv` mechanism columns (0 without a mask).
    pub nonconv_frac: f32,
}

/// Frozen-point maps of a column mask (`ny * nx`, no halo): `u` faces, `v` faces, centres/`w`
/// faces, each `nyh * nxh` (`air_picard.glsl:frozen_at`).
fn col_maps(k: &Consts, mask: &[u8]) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    let (nxh, nyh, nx, ny) = (k.nxh, k.nyh, k.nx, k.ny);
    let mut fc = vec![0u8; nxh * nyh];
    for j in 1..=ny {
        for i in 1..=nx {
            fc[j * nxh + i] = u8::from(mask[(j - 1) * nx + i - 1] != 0);
        }
    }
    let (mut fu, mut fv) = (fc.clone(), fc.clone());
    for j in 0..nyh {
        for i in 0..nxh {
            let q = j * nxh + i;
            if i > 0 {
                fu[q] |= fc[q - 1];
            }
            if j > 0 {
                fv[q] |= fc[q - nxh];
            }
        }
    }
    (fu, fv, fc)
}

/// `x <- a + w (x - a)` (`K_RELAX` with a uniform omega: the face mean of equal values is `w`).
fn relax_to(x: &mut [f32], a: &[f32], w: f32) {
    x.par_chunks_mut(4096)
        .zip(a.par_chunks(4096))
        .for_each(|(x, a)| {
            for (x, &a) in x.iter_mut().zip(a) {
                *x = a + w * (*x - a);
            }
        });
}

/// `dst <- src` or `dst += src` over the whole array.
fn acc(dst: &mut [f32], src: &[f32], add: bool) {
    dst.par_chunks_mut(4096)
        .zip(src.par_chunks(4096))
        .for_each(|(d, s)| {
            if add {
                for (d, &s) in d.iter_mut().zip(s) {
                    *d += s;
                }
            } else {
                d.copy_from_slice(s);
            }
        });
}

/// `nonconv` mechanism columns of the fallback (maps and the field to put there).
struct NcCtx {
    fu: Vec<u8>,
    fv: Vec<u8>,
    fc: Vec<u8>,
    field: Option<FrozenField>,
    frac: f32,
}

/// Fallback rules of one run (W11 v3; the game's `omega_fallback`, `late_from`, `nonconv_*`).
pub struct FbCtx {
    omega_after: usize,
    omega: f32,
    late_from: usize,
    nc: Option<NcCtx>,
    /// The omega rollback is on (`omega` is the effective multiplier `min(1, omega)`).
    omega_on: Option<f32>,
    /// Values before the step: `u, v, w, nu, nuh` (allocated at the switch).
    old: Option<[Vec<f32>; 5]>,
    /// Running sum of the states `u, v, w, th, thd` and their number.
    late: Option<[Vec<f32>; 5]>,
    late_n: usize,
}

impl FbCtx {
    fn late_on(&self) -> bool {
        self.late_from > 0 || self.nc.is_some()
    }
}

/// Frozen-column data of one run (W11; the game's `K_FREEZE`/`K_RMASK`/`K_FIXROW` state).
///
/// Column maps are `nyh * nxh` (halo columns are never frozen). A `u` face is frozen when its
/// own column or the column on its `-x` side is frozen, a `v` face likewise in `y`
/// (`air_picard.glsl:frozen_at`); cell centres and `w` faces follow their own column.
pub struct FreezeCtx {
    /// Frozen map of `u` faces, `v` faces, centres/`w` faces.
    fu: Vec<u8>,
    fv: Vec<u8>,
    fc: Vec<u8>,
    /// Frozen values `u, v, w, th, thd, nu, nuh` (halo layout).
    xf: [Vec<f32>; 7],
    /// Unknowns of `u, v, w` and fluid cells (`theta'`) outside the frozen columns.
    n_unk: [f64; 4],
    /// Fluid cells outside the frozen columns.
    n_free: f64,
    /// Fluid weights of the interior layout `(nz, ny, nx)`, zero in the frozen columns.
    fluid_free: Vec<f32>,
}

impl FreezeCtx {
    /// Frozen map of the unknown type `comp` (0 `u`, 1 `v`, else centre).
    fn cols(&self, comp: usize) -> &[u8] {
        match comp {
            0 => &self.fu,
            1 => &self.fv,
            _ => &self.fc,
        }
    }

    /// Fraction of frozen columns of the case (halo excluded).
    pub fn frozen_frac(&self, k: &Consts) -> f64 {
        let mut n = 0usize;
        for j in 1..=k.ny {
            n += self.fc[j * k.nxh + 1..j * k.nxh + 1 + k.nx]
                .iter()
                .filter(|&&c| c != 0)
                .count();
        }
        n as f64 / (k.nx * k.ny).max(1) as f64
    }

    /// No unknown is left: every fluid column is frozen.
    pub fn all_frozen(&self) -> bool {
        self.n_free == 0.0
    }
}

/// `x[t] <- xf[t]` in the frozen points (one task per halo row).
fn freeze_copy(x: &mut [f32], xf: &[f32], cols: &[u8], (nxh, nyh): (usize, usize)) {
    x.par_chunks_mut(nxh)
        .zip(xf.par_chunks(nxh))
        .enumerate()
        .for_each(|(r, (x, f))| {
            let c = &cols[(r % nyh) * nxh..][..nxh];
            for ((x, &f), &c) in x.iter_mut().zip(f).zip(c) {
                if c != 0 {
                    *x = f;
                }
            }
        });
}

/// Template rows of the frozen points become the identity `x = xf` (`K_FIXROW`).
fn freeze_fixrow(rows: &mut [Row], xf: &[f32], cols: &[u8], (nxh, nyh): (usize, usize)) {
    rows.par_chunks_mut(nxh)
        .zip(xf.par_chunks(nxh))
        .enumerate()
        .for_each(|(r, (rows, f))| {
            let c = &cols[(r % nyh) * nxh..][..nxh];
            for ((row, &f), &c) in rows.iter_mut().zip(f).zip(c) {
                if c != 0 {
                    *row = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, f];
                }
            }
        });
}

/// Residual of the frozen points to zero (`K_RMASK`, halo layout).
fn freeze_rmask(r: &mut [f32], cols: &[u8], (nxh, nyh): (usize, usize)) {
    r.par_chunks_mut(nxh).enumerate().for_each(|(i, r)| {
        let c = &cols[(i % nyh) * nxh..][..nxh];
        for (r, &c) in r.iter_mut().zip(c) {
            if c != 0 {
                *r = 0.0;
            }
        }
    });
}

/// Values of the interior layout `(nz, ny, nx)` of the frozen columns to zero (`K_RMASK`, kind 3).
fn freeze_imask(d: &mut [f32], fc: &[u8], k: &Consts) {
    let (nx, ny, nxh) = (k.nx, k.ny, k.nxh);
    d.par_chunks_mut(nx).enumerate().for_each(|(r, d)| {
        let c = &fc[(r % ny + 1) * nxh + 1..][..nx];
        for (d, &c) in d.iter_mut().zip(c) {
            if c != 0 {
                *d = 0.0;
            }
        }
    });
}

/// The iteration: constants, fields, multigrid and work buffers.
pub struct Picard {
    pub k: Consts,
    pub f: Fields,
    pub mg: Mg,
    pub cu: RowBuf,
    pub cv: RowBuf,
    pub cw: RowBuf,
    pub ct: RowBuf,
    pub ctd: RowBuf,
    pub rr: Vec<f32>,
    pub pfull: Vec<f32>,
    /// Fluid mask in the interior layout `(nz, ny, nx)` (index-free weights of the projection).
    pub fluid_int: Vec<f32>,
    pub div: Vec<f32>,
    pub sc: Scratch,
    /// Accumulated seconds of `outer_step` phases `[mom, heat, proj, kupd]` (main thread timers).
    pub phase: [f64; 4],
    /// Frozen columns (W11); `None` = the plain R6 v3 iteration.
    pub freeze: Option<FreezeCtx>,
    /// Cancel flag (W11), read after every iteration.
    pub cancel: Option<Arc<AtomicBool>>,
    /// W11 v6: the projection V-cycles also test `cancel` (setup: cold/warm start, `finalize`);
    /// off while iterating, where the flag is read after every iteration.
    pub prep_cancel: bool,
    /// A projection was cut short by `prep_cancel` (set by `project`, cleared by the caller).
    pub prep_cut: bool,
    /// Fallback rules (W11 v3); `None` = the plain iteration.
    pub fb: Option<FbCtx>,
}

/// Interior (no halo) copy of a halo array, layout `(nz, ny, nx)`.
fn interior(k: &Consts, a: &[f32]) -> Vec<f32> {
    let mut out = Vec::with_capacity(k.nx * k.ny * k.nz);
    for kk in 0..k.nz {
        for j in 0..k.ny {
            let g = ((kk + 1) * k.nyh + j + 1) * k.nxh + 1;
            out.extend_from_slice(&a[g..g + k.nx]);
        }
    }
    out
}

impl Picard {
    /// Allocates the iteration for the constants `k` (fields at the cold start state of K).
    pub fn new(k: Consts) -> Self {
        Self::new_cancel(k, None)
    }

    /// [`Self::new`] that stops building the multigrid levels once `cancel` is set (W11 v6):
    /// the solver is then weaker and must not be iterated (`api::solve` does not). The flag
    /// is also stored in `cancel`.
    pub fn new_cancel(k: Consts, cancel: Option<&Arc<AtomicBool>>) -> Self {
        let n = k.n3();
        let stop = || cancel.is_some_and(|c| c.load(Ordering::Relaxed));
        let mg = Mg::new_until(
            &k.kx,
            &k.ky,
            &k.kz,
            &k.fluid,
            (k.nzh, k.nyh, k.nxh),
            k.dx,
            k.dz,
            &stop,
        );
        let z = || vec![0.0f32; n];
        let zr = || RowBuf::zeros(n);
        let f = Fields {
            u: z(),
            v: z(),
            w: z(),
            th: z(),
            thd: z(),
            p: z(),
            nu: k.nu_bg.clone(),
            nuh: k.nu_bg.clone(),
        };
        Self {
            div: vec![0.0; k.nx * k.ny * k.nz],
            mg,
            f,
            cu: zr(),
            cv: zr(),
            cw: zr(),
            ct: zr(),
            ctd: zr(),
            rr: z(),
            pfull: z(),
            fluid_int: interior(&k, &k.fluid),
            sc: Scratch::new(n),
            phase: [0.0; 4],
            freeze: None,
            cancel: cancel.cloned(),
            prep_cancel: false,
            prep_cut: false,
            fb: None,
            k,
        }
    }

    fn shape(&self) -> (usize, usize, usize) {
        (self.k.nzh, self.k.nyh, self.k.nxh)
    }

    /// Divergence of the face velocities in air cells, interior layout `(nz, ny, nx)`.
    /// Row-wise: one task per `x` row, no per-element index arithmetic.
    pub fn divergence(k: &Consts, u: &[f32], v: &[f32], w: &[f32], out: &mut [f32]) {
        let (nxh, nyh) = (k.nxh, k.nyh);
        let (nx, ny) = (k.nx, k.ny);
        let (dx, dz) = (f64::from(k.dx), f64::from(k.dz));
        out.par_chunks_mut(nx).enumerate().for_each(|(r, o)| {
            let (j, kk) = (r % ny, r / ny);
            let g0 = ((kk + 1) * nyh + j + 1) * nxh + 1;
            let (u0, u1) = (&u[g0..g0 + nx], &u[g0 + 1..g0 + 1 + nx]);
            let (v0, v1) = (&v[g0..g0 + nx], &v[g0 + nxh..g0 + nxh + nx]);
            let (w0, w1) = (&w[g0..g0 + nx], &w[g0 + nxh * nyh..g0 + nxh * nyh + nx]);
            let fl = &k.fluid[g0..g0 + nx];
            for i in 0..nx {
                // f64 differences: with f32 the cancellation error of a nearly divergence-free
                // field (|u| / dx * 6e-8) is comparable to the divergence itself.
                let du = (f64::from(u1[i]) - f64::from(u0[i])) / dx;
                let dv = (f64::from(v1[i]) - f64::from(v0[i])) / dx;
                let dw = (f64::from(w1[i]) - f64::from(w0[i])) / dz;
                o[i] = ((du + dv + dw) * f64::from(fl[i])) as f32;
            }
        });
    }

    /// Pressure projection: `cycles` V-cycles for `div(K grad phi) = div u - mean`,
    /// velocity correction, and `p += phi` when `update_p`.
    ///
    /// All passes are row-wise in the rayon pool; the mean-free `phi` is written only into the
    /// interior of `pfull` (its halo cells are zero from allocation and never written).
    pub fn project(&mut self, cycles: usize, update_p: bool) {
        self.project_impl(cycles, update_p, false);
    }

    /// [`Self::project`]; `masked` (W11, only with frozen columns): the divergence of the
    /// frozen columns does not enter the right-hand side and the compatibility mean is over the
    /// free fluid cells (`_prog_project(masked)` of the game). The correction `phi` is still
    /// applied everywhere.
    fn project_impl(&mut self, cycles: usize, update_p: bool, masked: bool) {
        let k = &self.k;
        let nx = k.nx;
        Self::divergence(k, &self.f.u, &self.f.v, &self.f.w, &mut self.div);
        let fi = &self.fluid_int;
        let (mean, wr) = match self.freeze.as_ref().filter(|_| masked) {
            Some(z) => {
                freeze_imask(&mut self.div, &z.fc, k);
                let div = &self.div;
                let m = det_sum(div.len(), |q| f64::from(div[q])) / z.n_free.max(1.0);
                (m as f32, &z.fluid_free)
            }
            None => (
                (det_sum(self.div.len(), |q| f64::from(self.div[q])) / k.n_fluid) as f32,
                fi,
            ),
        };
        // rhs = div - mean * fluid goes straight into the finest-level rows (no pass over `div`),
        // and phi is zeroed in the same pass (masked: the weights are zero in the frozen
        // columns, so is the right-hand side there).
        self.mg.set_rhs_shifted_zero(&self.div, mean, wr);
        let (armed, cancel) = (self.prep_cancel, self.cancel.clone());
        let stop = || armed && cancel.as_ref().is_some_and(|c| c.load(Ordering::Relaxed));
        for _ in 0..cycles {
            if !self.mg.vcycle_until(&stop) {
                self.prep_cut = true;
                break;
            }
        }
        let phi = self.mg.phi();
        let pm = (det_sum(phi.len(), |q| f64::from(phi[q] * fi[q])) / k.n_fluid) as f32;
        // phi - pm * fluid is written straight into the interior of `pfull` (no pass over `phi`).
        let (nxh, nyh, ny) = (k.nxh, k.nyh, k.ny);
        self.pfull
            .par_chunks_mut(nxh)
            .enumerate()
            .for_each(|(hr, row)| {
                let (kk, j) = (hr / nyh, hr % nyh);
                if (1..=k.nz).contains(&kk) && (1..=ny).contains(&j) {
                    let r = (kk - 1) * ny + (j - 1);
                    let (x, f) = (&phi[r * nx..(r + 1) * nx], &fi[r * nx..(r + 1) * nx]);
                    for ((o, &x), &f) in row[1..=nx].iter_mut().zip(x).zip(f) {
                        *o = x - pm * f;
                    }
                }
            });
        Self::apply_phi(k, &self.pfull, &mut self.f, update_p);
    }

    /// Applies a halo-layout correction potential `pf` to the velocities (and to `p`):
    /// one pass, one task per halo `x` row.
    pub fn apply_phi(k: &Consts, pf: &[f32], f: &mut Fields, update_p: bool) {
        let (nx, ny) = (k.nxh, k.nyh);
        let (dx, dz) = (k.dx, k.dz);
        let Fields { u, v, w, p, .. } = f;
        u.par_chunks_mut(nx)
            .zip(v.par_chunks_mut(nx))
            .zip(w.par_chunks_mut(nx))
            .zip(p.par_chunks_mut(nx))
            .enumerate()
            .for_each(|(r, (((u, v), w), p))| {
                let o = r * nx;
                let pc = &pf[o..o + nx];
                let kx = &k.kx[o..o + nx];
                for i in 1..nx {
                    u[i] -= kx[i] * (pc[i] - pc[i - 1]) / dx;
                }
                if r % ny != 0 {
                    let pm = &pf[o - nx..o];
                    let ky = &k.ky[o..o + nx];
                    for i in 0..nx {
                        v[i] -= ky[i] * (pc[i] - pm[i]) / dx;
                    }
                }
                if r >= ny {
                    let pm = &pf[o - nx * ny..o - nx * ny + nx];
                    let kz = &k.kz[o..o + nx];
                    for i in 0..nx {
                        w[i] -= kz[i] * (pc[i] - pm[i]) / dz;
                    }
                }
                if update_p {
                    for (p, &d) in p.iter_mut().zip(pc) {
                        *p += d;
                    }
                }
            });
    }

    /// Momentum stencils of the three components from the current state.
    pub fn build_all_mom(&mut self) {
        let f = &self.f;
        let m = MomIn {
            vel: Vel {
                u: &f.u,
                v: &f.v,
                w: &f.w,
            },
            p: &f.p,
            th: &f.th,
            nu: &f.nu,
            nuh: &f.nuh,
        };
        build_all_mom(&self.k, &m, &mut self.cu, &mut self.cv, &mut self.cw);
    }

    /// Heat template for theta'_d from the current state.
    pub fn build_heat_d(&mut self) {
        let f = &self.f;
        let h = HeatIn {
            vel: Vel {
                u: &f.u,
                v: &f.v,
                w: &f.w,
            },
            x: &f.thd,
            q: &self.k.q,
            q_sub: None,
            gam: None,
            nu: &f.nu,
            nuh: &f.nuh,
            inv_tau: self.k.inv_tau,
        };
        build_heat(&self.k, &h, &mut self.ctd);
    }

    /// Heat template for the full theta' (source `Q - theta'_d / tau`).
    pub fn build_heat_t(&mut self) {
        let k = &self.k;
        let f = &self.f;
        let h = HeatIn {
            vel: Vel {
                u: &f.u,
                v: &f.v,
                w: &f.w,
            },
            x: &f.th,
            q: &k.q,
            q_sub: Some((&f.thd, k.inv_tau)),
            gam: Some(&k.gam),
            nu: &f.nu,
            nuh: &f.nuh,
            inv_tau: 0.0,
        };
        build_heat(k, &h, &mut self.ct);
    }

    /// Frozen points of the momentum templates become the identity `x = xf` (`K_FIXROW`).
    fn fix_mom_rows(&mut self) {
        if let Some(z) = &self.freeze {
            let hd = (self.k.nxh, self.k.nyh);
            freeze_fixrow(&mut self.cu, &z.xf[0], &z.fu, hd);
            freeze_fixrow(&mut self.cv, &z.xf[1], &z.fv, hd);
            freeze_fixrow(&mut self.cw, &z.xf[2], &z.fc, hd);
        }
    }

    /// Frozen points of `u, v, w, theta', theta'_d, nu, nuh` take the frozen values
    /// (`_rec_freeze`: after every iteration, and for an all-frozen run before `finalize`).
    pub fn freeze_apply(&mut self) {
        let Some(z) = &self.freeze else { return };
        let hd = (self.k.nxh, self.k.nyh);
        let f = &mut self.f;
        freeze_copy(&mut f.u, &z.xf[0], &z.fu, hd);
        freeze_copy(&mut f.v, &z.xf[1], &z.fv, hd);
        freeze_copy(&mut f.w, &z.xf[2], &z.fc, hd);
        freeze_copy(&mut f.th, &z.xf[3], &z.fc, hd);
        freeze_copy(&mut f.thd, &z.xf[4], &z.fc, hd);
        freeze_copy(&mut f.nu, &z.xf[5], &z.fc, hd);
        freeze_copy(&mut f.nuh, &z.xf[6], &z.fc, hd);
    }

    /// Lengths of a [`crate::api::Freeze`] against the grid of `k` (an error, never a panic).
    pub fn new_check_freeze(k: &Consts, fr: &crate::api::Freeze) -> Result<()> {
        Self::new_check_freeze_parts(k, &fr.mask, fr.field.as_ref())
    }

    fn check_field(what: &str, k: &Consts, fl: &FrozenField) -> Result<()> {
        for (nm, a) in [("u", &fl.u), ("v", &fl.v), ("w", &fl.w), ("th", &fl.th)]
            .into_iter()
            .chain(fl.thd.as_ref().map(|t| ("thd", t)))
        {
            if a.len() != k.n3() {
                anyhow::bail!(
                    "{what}.{nm} has {} values, the grid with halo has {}",
                    a.len(),
                    k.n3()
                );
            }
        }
        Ok(())
    }

    fn new_check_freeze_parts(k: &Consts, mask: &[u8], field: Option<&FrozenField>) -> Result<()> {
        let (nx, ny) = (k.nx, k.ny);
        if mask.len() != nx * ny {
            anyhow::bail!(
                "freeze.mask has {} columns, the case has ny*nx = {}",
                mask.len(),
                nx * ny
            );
        }
        if let Some(fl) = field {
            Self::check_field("freeze.field", k, fl)?;
        }
        Ok(())
    }

    /// Declares frozen columns (W11); call after the start (`init_background`/`init_warm`):
    /// channels `field` does not give, and `nu`, `nuh`, are taken from the current fields
    /// (the game's `fsnap`). `mask` is `ny * nx` without halo (halo columns are not frozen);
    /// an all-zero mask leaves the iteration untouched (bitwise the plain one).
    pub fn set_freeze(&mut self, mask: &[u8], field: Option<&FrozenField>) -> Result<()> {
        Self::new_check_freeze_parts(&self.k, mask, field)?;
        let k = &self.k;
        let (nxh, nyh) = (k.nxh, k.nyh);
        self.freeze = None;
        if mask.iter().all(|&m| m == 0) {
            return Ok(());
        }
        let (fu, fv, fc) = col_maps(k, mask);
        let cur = &self.f;
        let own = |a: &Vec<f32>, g: Option<&Vec<f32>>| g.unwrap_or(a).clone();
        let xf = [
            own(&cur.u, field.map(|f| &f.u)),
            own(&cur.v, field.map(|f| &f.v)),
            own(&cur.w, field.map(|f| &f.w)),
            own(&cur.th, field.map(|f| &f.th)),
            own(&cur.thd, field.and_then(|f| f.thd.as_ref())),
            cur.nu.clone(),
            cur.nuh.clone(),
        ];
        // Counts are sums of 0/1 weights: exact in f64 in any order.
        let count = |w: &[f32], cols: &[u8]| -> f64 {
            w.par_chunks(nxh)
                .enumerate()
                .map(|(r, w)| {
                    let c = &cols[(r % nyh) * nxh..][..nxh];
                    w.iter()
                        .zip(c)
                        .filter(|&(_, &c)| c == 0)
                        .map(|(&w, _)| f64::from(w))
                        .sum::<f64>()
                })
                .collect::<Vec<f64>>()
                .iter()
                .sum()
        };
        let n_unk = [
            count(&k.mu[0], &fu),
            count(&k.mu[1], &fv),
            count(&k.mu[2], &fc),
            count(&k.fluid, &fc),
        ];
        let mut fluid_free = self.fluid_int.clone();
        freeze_imask(&mut fluid_free, &fc, k);
        self.freeze = Some(FreezeCtx {
            n_free: n_unk[3],
            fu,
            fv,
            fc,
            xf,
            n_unk,
            fluid_free,
        });
        Ok(())
    }

    /// Declares the fallback rules (W11 v3); call once before [`Picard::solve`]. Lengths and
    /// values are validated (an error, never a panic).
    pub fn set_fallback(&mut self, fb: &Fallback) -> Result<()> {
        let k = &self.k;
        if fb.omega_after > 0 && !(fb.omega.is_finite() && fb.omega > 0.0) {
            anyhow::bail!("fallback.omega must be finite and > 0, got {}", fb.omega);
        }
        let nc = match &fb.nonconv {
            None => None,
            Some(nc) => {
                if nc.mask.len() != k.nx * k.ny {
                    anyhow::bail!(
                        "fallback.nonconv.mask has {} columns, the case has ny*nx = {}",
                        nc.mask.len(),
                        k.nx * k.ny
                    );
                }
                if let Some(fl) = &nc.field {
                    Self::check_field("fallback.nonconv.field", k, fl)?;
                }
                let cnt = nc.mask.iter().filter(|&&m| m != 0).count();
                let (fu, fv, fc) = col_maps(k, &nc.mask);
                Some(NcCtx {
                    fu,
                    fv,
                    fc,
                    field: nc.field.clone(),
                    frac: cnt as f32 / (k.nx * k.ny).max(1) as f32,
                })
            }
        };
        let mut ctx = FbCtx {
            omega_after: fb.omega_after,
            omega: fb.omega.min(1.0),
            late_from: fb.late_from,
            nc,
            omega_on: None,
            old: None,
            late: None,
            late_n: 0,
        };
        if ctx.late_on() {
            let z = || vec![0.0f32; k.n3()];
            ctx.late = Some([z(), z(), z(), z(), z()]);
        }
        self.fb = Some(ctx);
        Ok(())
    }

    fn relax_on(&self) -> bool {
        self.fb.as_ref().is_some_and(|b| b.omega_on.is_some())
    }

    /// After a residual check without a stop: accumulate `late_mean` and switch omega
    /// (`air_picard_job.gd:_step_program`/`_after_sync`).
    fn fb_after_check(&mut self, it: usize) {
        let Some(b) = self.fb.as_mut() else { return };
        if b.late_on()
            && it >= b.late_from
            && it > 0
            && let Some(sum) = b.late.as_mut()
        {
            let f = &self.f;
            let first = b.late_n == 0;
            for (s, x) in sum.iter_mut().zip([&f.u, &f.v, &f.w, &f.th, &f.thd]) {
                acc(s, x, !first);
            }
            b.late_n += 1;
        }
        if b.omega_after > 0 && b.omega_on.is_none() && it >= b.omega_after {
            b.omega_on = Some(b.omega);
            let n = self.k.n3();
            b.old = Some([
                vec![0.0; n],
                vec![0.0; n],
                vec![0.0; n],
                vec![0.0; n],
                vec![0.0; n],
            ]);
        }
    }

    /// Stopped at `max_iters` unconverged: field := `late_mean`, in the `nonconv` columns :=
    /// `nonconv.field`. Returns whether it was applied. As in the game, frozen columns are not restored: they hold
    /// the mean of their constant field (may differ in the last bit).
    fn fb_apply_late(&mut self) -> bool {
        let Some(b) = self.fb.as_mut() else {
            return false;
        };
        if !b.late_on() || b.late_n == 0 {
            return false;
        }
        let Some(sum) = b.late.as_ref() else {
            return false;
        };
        let inv = (1.0f64 / b.late_n as f64) as f32;
        let f = &mut self.f;
        for (x, s) in [&mut f.u, &mut f.v, &mut f.w, &mut f.th, &mut f.thd]
            .into_iter()
            .zip(sum)
        {
            x.par_chunks_mut(4096)
                .zip(s.par_chunks(4096))
                .for_each(|(x, s)| {
                    for (x, &s) in x.iter_mut().zip(s) {
                        *x = s * inv;
                    }
                });
        }
        if let Some(nc) = &b.nc
            && let Some(fl) = &nc.field
        {
            let hd = (self.k.nxh, self.k.nyh);
            freeze_copy(&mut f.u, &fl.u, &nc.fu, hd);
            freeze_copy(&mut f.v, &fl.v, &nc.fv, hd);
            freeze_copy(&mut f.w, &fl.w, &nc.fc, hd);
            freeze_copy(&mut f.th, &fl.th, &nc.fc, hd);
            if let Some(t) = &fl.thd {
                freeze_copy(&mut f.thd, t, &nc.fc, hd);
            }
        }
        true
    }

    /// True once the cancel flag is set.
    fn cancelled(&self) -> bool {
        self.cancel
            .as_ref()
            .is_some_and(|c| c.load(Ordering::Relaxed))
    }

    /// Momentum step: `mom_sweeps` times (u, v, w) line sweeps in (z, x, y).
    pub fn mom_step(&mut self) {
        let shape = self.shape();
        for _ in 0..self.k.mom_sweeps {
            sweep(&self.cu, &mut self.f.u, &mut self.sc, shape, &[2, 0, 1]);
            sweep(&self.cv, &mut self.f.v, &mut self.sc, shape, &[2, 0, 1]);
            sweep(&self.cw, &mut self.f.w, &mut self.sc, shape, &[2, 0, 1]);
        }
    }

    /// Heat step: theta'_d template and sweeps, then theta' template (from the new theta'_d)
    /// and sweeps. The theta'_d pass is skipped when there is no heating.
    pub fn heat_step(&mut self) {
        let shape = self.shape();
        if !self.k.no_thd {
            self.build_heat_d();
            if let Some(z) = &self.freeze {
                let hd = (self.k.nxh, self.k.nyh);
                freeze_fixrow(&mut self.ctd, &z.xf[4], &z.fc, hd);
            }
            for _ in 0..self.k.heat_sweeps {
                sweep(&self.ctd, &mut self.f.thd, &mut self.sc, shape, &[2, 0, 1]);
            }
        }
        self.build_heat_t();
        if let Some(z) = &self.freeze {
            let hd = (self.k.nxh, self.k.nyh);
            freeze_fixrow(&mut self.ct, &z.xf[3], &z.fc, hd);
        }
        for _ in 0..self.k.heat_sweeps {
            sweep(&self.ct, &mut self.f.th, &mut self.sc, shape, &[2, 0, 1]);
        }
    }

    /// Local K update with the current fields (if enabled).
    pub fn update_k(&mut self) {
        if self.k.local_k {
            let f = &mut self.f;
            let vel = Vel {
                u: &f.u,
                v: &f.v,
                w: &f.w,
            };
            kloc(&self.k, &vel, &f.th, &mut f.nu, &mut f.nuh);
        }
    }

    /// One Picard iteration (reference `outer_step`).
    pub fn outer_step(&mut self) {
        apply_bc(&self.k, &mut self.f.u, &mut self.f.v);
        let relax = self.relax_on();
        let t = Instant::now();
        if relax {
            self.relax_save(&[3, 4]);
        }
        self.update_k();
        if relax {
            self.relax_apply(&[3, 4]);
            self.relax_save(&[0, 1, 2]);
        }
        let t_k = t.elapsed().as_secs_f64();
        let t = Instant::now();
        self.build_all_mom();
        self.fix_mom_rows();
        self.mom_step();
        let t_m = t.elapsed().as_secs_f64();
        let t = Instant::now();
        self.project_impl(self.k.vcycles, true, self.freeze.is_some());
        let t_p = t.elapsed().as_secs_f64();
        if relax {
            self.relax_apply(&[0, 1, 2]);
        }
        let t = Instant::now();
        self.heat_step();
        self.freeze_apply();
        let t_h = t.elapsed().as_secs_f64();
        for (a, d) in self.phase.iter_mut().zip([t_m, t_h, t_p, t_k]) {
            *a += d;
        }
    }

    fn chan(f: &mut Fields, c: usize) -> &mut Vec<f32> {
        match c {
            0 => &mut f.u,
            1 => &mut f.v,
            2 => &mut f.w,
            3 => &mut f.nu,
            _ => &mut f.nuh,
        }
    }

    /// Remember the channels `cs` (`u, v, w, nu, nuh` = 0..5) before the step (omega rollback).
    fn relax_save(&mut self, cs: &[usize]) {
        let Some(old) = self.fb.as_mut().and_then(|b| b.old.as_mut()) else {
            return;
        };
        for &c in cs {
            if c >= 3 && !self.k.local_k {
                continue;
            }
            old[c].copy_from_slice(Self::chan(&mut self.f, c));
        }
    }

    /// `x <- old + omega (x - old)` for the channels `cs`.
    fn relax_apply(&mut self, cs: &[usize]) {
        let Some(b) = self.fb.as_ref() else { return };
        let (Some(w), Some(old)) = (b.omega_on, b.old.as_ref()) else {
            return;
        };
        for &c in cs {
            if c >= 3 && !self.k.local_k {
                continue;
            }
            relax_to(Self::chan(&mut self.f, c), &old[c], w);
        }
    }

    /// Residual of the steady equations in the current state (reference `residuals`).
    pub fn residuals(&mut self) -> Residuals {
        let shape = self.shape();
        let n = self.k.n3();
        apply_bc(&self.k, &mut self.f.u, &mut self.f.v);
        self.build_all_mom();
        let mut mom_max = 0.0f64;
        let mut mom_sq = 0.0f64;
        for comp in 0..3 {
            let (rows, x) = match comp {
                0 => (&self.cu, &self.f.u),
                1 => (&self.cv, &self.f.v),
                _ => (&self.cw, &self.f.w),
            };
            resid(rows, x, shape, &mut self.rr);
            if let Some(z) = &self.freeze {
                freeze_rmask(&mut self.rr, z.cols(comp), (self.k.nxh, self.k.nyh));
            }
            let m = &self.k.mu[comp];
            let rr = &self.rr;
            let mx = par_max(n, |q| f64::from((rr[q] * m[q]).abs()));
            let s2 = det_sum(n, |q| f64::from(rr[q] * m[q]).powi(2));
            let cnt = match &self.freeze {
                Some(z) => z.n_unk[comp].max(1.0),
                None => det_sum(n, |q| f64::from(m[q])),
            };
            mom_max = if mx.is_nan() { mx } else { mom_max.max(mx) };
            mom_sq += s2 / cnt;
        }
        self.build_heat_d();
        self.build_heat_t();
        let nf = self
            .freeze
            .as_ref()
            .map_or(self.k.n_fluid, |z| z.n_free.max(1.0));
        let fl = &self.k.fluid;
        let hd = (self.k.nxh, self.k.nyh);
        resid(&self.ct, &self.f.th, shape, &mut self.rr);
        if let Some(z) = &self.freeze {
            freeze_rmask(&mut self.rr, &z.fc, hd);
        }
        let rr = &self.rr;
        let th_max = par_max(n, |q| f64::from((rr[q] * fl[q]).abs()));
        let th_rms = (det_sum(n, |q| f64::from(rr[q] * fl[q]).powi(2)) / nf).sqrt();
        resid(&self.ctd, &self.f.thd, shape, &mut self.rr);
        if let Some(z) = &self.freeze {
            freeze_rmask(&mut self.rr, &z.fc, hd);
        }
        let rr = &self.rr;
        let thd_max = par_max(n, |q| f64::from((rr[q] * fl[q]).abs()));
        let thd_rms = (det_sum(n, |q| f64::from(rr[q] * fl[q]).powi(2)) / nf).sqrt();
        Self::divergence(&self.k, &self.f.u, &self.f.v, &self.f.w, &mut self.div);
        if let Some(z) = &self.freeze {
            // Free columns only, minus their mean: the constant compatibility part of the
            // frozen field's flux through shared faces is not a solution error.
            freeze_imask(&mut self.div, &z.fc, &self.k);
            let d = &self.div;
            let mean = (det_sum(d.len(), |q| f64::from(d[q])) / nf) as f32;
            let fl = &z.fluid_free;
            self.div
                .par_iter_mut()
                .zip(fl.par_iter())
                .for_each(|(d, &w)| *d -= mean * w);
        }
        let d = &self.div;
        let div_rms = (det_sum(d.len(), |q| f64::from(d[q]).powi(2)) / nf).sqrt();
        Residuals {
            mom_max,
            mom_rms: (mom_sq / 3.0).sqrt(),
            th_max: th_max.max(thd_max),
            th_rms: th_rms.max(thd_rms),
            thd_rms,
            div_rms,
        }
    }

    /// Cold start: background wind on type-1 faces, zero theta', 30 projection V-cycles,
    /// `p = 0` (reference `init_background`).
    pub fn init_background(&mut self) {
        let k = &self.k;
        let f = &mut self.f;
        for i in 0..k.n3() {
            f.u[i] = if k.tu[i] == 1 { k.ubg[i] } else { 0.0 };
            f.v[i] = if k.tv[i] == 1 { k.vbg[i] } else { 0.0 };
            f.w[i] = 0.0;
        }
        f.th.fill(0.0);
        f.thd.fill(0.0);
        f.p.fill(0.0);
        for i in 0..k.n3() {
            if k.tu[i] == 3 {
                f.u[i] = k.ubg[i];
            }
            if k.tu[i] == 0 {
                f.u[i] = 0.0;
            }
            if k.tv[i] == 3 {
                f.v[i] = k.vbg[i];
            }
            if k.tv[i] == 0 {
                f.v[i] = 0.0;
            }
            if k.tw[i] != 1 {
                f.w[i] = 0.0;
            }
        }
        apply_bc(k, &mut f.u, &mut f.v);
        self.project(30, true);
        self.f.p.fill(0.0);
    }

    /// Warm start as in the game (`air_picard_job.gd:_program("warm")`): `u, v, w, th, thd, p`
    /// from the snapshot, `nu`/`nuh` and the whole input from this case (fresh, as after
    /// `Picard::new`), boundary conditions from the field (not from the background) and
    /// 4 projection V-cycles (instead of 30) without touching `p`.
    pub fn init_warm(&mut self, st: &State) -> Result<()> {
        st.check_dims(&self.k)?;
        let f = &mut self.f;
        f.u.copy_from_slice(&st.u);
        f.v.copy_from_slice(&st.v);
        f.w.copy_from_slice(&st.w);
        f.th.copy_from_slice(&st.th);
        f.thd.copy_from_slice(&st.thd);
        f.p.copy_from_slice(&st.p);
        apply_bc(&self.k, &mut self.f.u, &mut self.f.v);
        self.project(4, false);
        Ok(())
    }

    /// Fields as `finalize` would deliver them now, taken on a copy: the running state
    /// (velocities) is restored, so the iteration continues unchanged.
    pub fn finalized_copy(&mut self, cycles: usize) -> Fields {
        let (u, v, w) = (self.f.u.clone(), self.f.v.clone(), self.f.w.clone());
        self.finalize(cycles);
        let out = self.f.clone();
        self.f.u = u;
        self.f.v = v;
        self.f.w = w;
        out
    }

    /// Final projection to near-exact divergence without changing `p` (`cycles` V-cycles).
    pub fn finalize(&mut self, cycles: usize) {
        apply_bc(&self.k, &mut self.f.u, &mut self.f.v);
        self.project(cycles, false);
    }

    /// Residual check now; appends it to `hist` (time `t_s` since `t_start`) and adds its cost to `check_s`.
    fn check_into(
        &mut self,
        it: usize,
        t_start: Instant,
        hist: &mut Vec<Check>,
        check_s: &mut f64,
    ) {
        let t = Instant::now();
        let res = self.residuals();
        *check_s += t.elapsed().as_secs_f64();
        hist.push(Check {
            it,
            res,
            t_s: t_start.elapsed().as_secs_f64(),
        });
    }

    /// Runs the iteration from the current start state (cold or warm) until the criterion,
    /// `max_iters`, the time budget or divergence (reference `solve`; the first check happens
    /// `check_every` iterations after `pre_steps`). The loop is per iteration, so `max_iters`,
    /// the time budget and snapshots act exactly after the requested iteration; the order of
    /// operations is that of the reference. A check is added at the last iteration if it was
    /// not one, so `history.last()` always gives the residuals of the delivered field.
    pub fn solve(&mut self, crit: &Criterion, run: &RunLimits) -> SolveOut {
        if self.k.no_thd {
            self.f.thd.fill(0.0);
        }
        // Nothing to solve: the frozen field (the game goes straight to `final`).
        let all_frozen = self.freeze.as_ref().is_some_and(FreezeCtx::all_frozen);
        if all_frozen {
            self.freeze_apply();
        }
        let pre_cancel = !all_frozen && self.cancelled();
        let mut hist: Vec<Check> = Vec::new();
        let mut snaps: Vec<RawSnapshot> = Vec::new();
        let mut stop = if all_frozen {
            StopReason::AllFrozen
        } else if pre_cancel {
            StopReason::Cancelled
        } else {
            StopReason::MaxIters
        };
        let (mut iter_s, mut check_s) = (0.0, 0.0);
        let ph0 = self.phase;
        let t_start = Instant::now();
        let mut want = run.snapshot_at.iter().copied().peekable();
        let mut it = 0usize;
        if want.next_if_eq(&0).is_some() {
            snaps.push(RawSnapshot {
                it,
                f: self.finalized_copy(10),
                res: None,
            });
        }
        // The game's count: `max_outer` against `_iters`, which has no cold-start `pre_steps`.
        // It acts at the nearest check from above (`air_picard_job.gd:1013`), not mid-batch.
        let limit = if run.max_iters == 0 {
            0
        } else {
            crit.pre_steps + run.max_iters.div_ceil(crit.check_every) * crit.check_every
        };
        while it < limit && !all_frozen && !pre_cancel {
            let t = Instant::now();
            self.outer_step();
            iter_s += t.elapsed().as_secs_f64();
            it += 1;
            let mut verdict = None;
            if it > crit.pre_steps && (it - crit.pre_steps).is_multiple_of(crit.check_every) {
                self.check_into(it, t_start, &mut hist, &mut check_s);
                let r = hist[hist.len() - 1].res;
                let finite = [r.mom_max, r.mom_rms, r.th_rms, r.div_rms]
                    .iter()
                    .all(|x| x.is_finite());
                if !finite || r.mom_max > 50.0 {
                    verdict = Some(StopReason::Diverged);
                } else if r.mom_rms < crit.tol_mom_rms
                    && r.th_rms < crit.tol_th_rms
                    && r.div_rms < crit.tol_div_rms
                {
                    verdict = Some(StopReason::Converged);
                }
            }
            if want.next_if_eq(&it).is_some() {
                let res = hist.last().filter(|c| c.it == it).copied();
                snaps.push(RawSnapshot {
                    it,
                    f: self.finalized_copy(10),
                    res,
                });
            }
            if let Some(v) = verdict {
                stop = v;
                break;
            }
            if it >= limit {
                break;
            }
            if it > crit.pre_steps && (it - crit.pre_steps).is_multiple_of(crit.check_every) {
                // The game counts `_iters` in whole checks, without the cold-start `pre_steps`.
                self.fb_after_check(it - crit.pre_steps);
            }
            if self.cancelled() {
                stop = StopReason::Cancelled;
                break;
            }
            if run.time_budget.is_some_and(|b| t_start.elapsed() >= b) {
                stop = StopReason::TimeBudget;
                break;
            }
        }
        if hist.last().is_none_or(|c| c.it != it) {
            if pre_cancel {
                // W11 v6: cancelled before the first iteration - no residual pass (it costs about
                // an iteration); the record at `it = 0` is NaN: not computed.
                let nan = f64::NAN;
                hist.push(Check {
                    it,
                    res: Residuals {
                        mom_max: nan,
                        mom_rms: nan,
                        th_max: nan,
                        th_rms: nan,
                        thd_rms: nan,
                        div_rms: nan,
                    },
                    t_s: t_start.elapsed().as_secs_f64(),
                });
            } else {
                self.check_into(it, t_start, &mut hist, &mut check_s);
            }
        }
        // W11 v3: unconverged at `max_iters` - the late mean replaces the field (the residuals
        // above stay those of the last iterate).
        let nonconv_fallback = stop == StopReason::MaxIters && self.fb_apply_late();
        let mut phase_s = [0.0; 5];
        for i in 0..4 {
            phase_s[i] = self.phase[i] - ph0[i];
        }
        phase_s[4] = (iter_s - phase_s[..4].iter().sum::<f64>()).max(0.0);
        SolveOut {
            status: stop.status(),
            stop,
            iters: it,
            n_checks: hist.len(),
            history: hist,
            iter_s,
            check_s,
            phase_s,
            snapshots: snaps,
            omega_fallback_used: self.fb.as_ref().is_some_and(|b| b.omega_on.is_some()),
            nonconv_fallback,
            nonconv_frac: self
                .fb
                .as_ref()
                .and_then(|b| b.nc.as_ref())
                .map_or(0.0, |n| n.frac),
        }
    }
}
