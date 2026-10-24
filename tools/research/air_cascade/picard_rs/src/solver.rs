//! The Picard iteration state and driver: outer step, projection, residuals, stopping
//! criterion, finalize — reference `Air.outer_step`, `project`, `residuals`, `solve`,
//! `finalize` (`air.py`) with the second-order advection correction off.

use crate::case::{Consts, Criterion};
use crate::kernels::{HeatIn, MomIn, Vel, apply_bc, build_all_mom, build_heat, kloc};
use crate::lines::{RowBuf, Scratch, resid, sweep};
use crate::mg::Mg;
use crate::state::State;
use crate::util::{det_sum, par_max};
use anyhow::Result;
use rayon::prelude::*;
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
}

impl StopReason {
    /// Name in the R2 `stop` field.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Converged => "converged",
            Self::MaxIters => "max_iters",
            Self::TimeBudget => "time_budget",
            Self::Diverged => "diverged",
        }
    }

    /// Legacy R2 `status`: `ok` | `max` | `diverged`.
    pub fn status(self) -> &'static str {
        match self {
            Self::Converged => "ok",
            Self::MaxIters | Self::TimeBudget => "max",
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
        let n = k.n3();
        let mg = Mg::new(
            &k.kx,
            &k.ky,
            &k.kz,
            &k.fluid,
            (k.nzh, k.nyh, k.nxh),
            k.dx,
            k.dz,
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
        let k = &self.k;
        let nx = k.nx;
        Self::divergence(k, &self.f.u, &self.f.v, &self.f.w, &mut self.div);
        let fi = &self.fluid_int;
        let mean = (det_sum(self.div.len(), |q| f64::from(self.div[q])) / k.n_fluid) as f32;
        // rhs = div - mean * fluid goes straight into the finest-level rows (no pass over `div`),
        // and phi is zeroed in the same pass.
        self.mg.set_rhs_shifted_zero(&self.div, mean, fi);
        for _ in 0..cycles {
            self.mg.vcycle();
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
            for _ in 0..self.k.heat_sweeps {
                sweep(&self.ctd, &mut self.f.thd, &mut self.sc, shape, &[2, 0, 1]);
            }
        }
        self.build_heat_t();
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
        let t = Instant::now();
        self.update_k();
        let t_k = t.elapsed().as_secs_f64();
        let t = Instant::now();
        self.build_all_mom();
        self.mom_step();
        let t_m = t.elapsed().as_secs_f64();
        let t = Instant::now();
        self.project(self.k.vcycles, true);
        let t_p = t.elapsed().as_secs_f64();
        let t = Instant::now();
        self.heat_step();
        let t_h = t.elapsed().as_secs_f64();
        for (a, d) in self.phase.iter_mut().zip([t_m, t_h, t_p, t_k]) {
            *a += d;
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
            let m = &self.k.mu[comp];
            let rr = &self.rr;
            let mx = par_max(n, |q| f64::from((rr[q] * m[q]).abs()));
            let s2 = det_sum(n, |q| f64::from(rr[q] * m[q]).powi(2));
            let cnt = det_sum(n, |q| f64::from(m[q]));
            mom_max = if mx.is_nan() { mx } else { mom_max.max(mx) };
            mom_sq += s2 / cnt;
        }
        self.build_heat_d();
        self.build_heat_t();
        let nf = self.k.n_fluid;
        let fl = &self.k.fluid;
        resid(&self.ct, &self.f.th, shape, &mut self.rr);
        let rr = &self.rr;
        let th_max = par_max(n, |q| f64::from((rr[q] * fl[q]).abs()));
        let th_rms = (det_sum(n, |q| f64::from(rr[q] * fl[q]).powi(2)) / nf).sqrt();
        resid(&self.ctd, &self.f.thd, shape, &mut self.rr);
        let rr = &self.rr;
        let thd_max = par_max(n, |q| f64::from((rr[q] * fl[q]).abs()));
        let thd_rms = (det_sum(n, |q| f64::from(rr[q] * fl[q]).powi(2)) / nf).sqrt();
        Self::divergence(&self.k, &self.f.u, &self.f.v, &self.f.w, &mut self.div);
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
        let mut hist: Vec<Check> = Vec::new();
        let mut snaps: Vec<RawSnapshot> = Vec::new();
        let mut stop = StopReason::MaxIters;
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
        while it < run.max_iters {
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
            if it >= run.max_iters {
                break;
            }
            if run.time_budget.is_some_and(|b| t_start.elapsed() >= b) {
                stop = StopReason::TimeBudget;
                break;
            }
        }
        if hist.last().is_none_or(|c| c.it != it) {
            self.check_into(it, t_start, &mut hist, &mut check_s);
        }
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
        }
    }
}
