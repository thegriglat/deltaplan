//! The Picard iteration state and driver: outer step, projection, residuals, stopping
//! criterion, finalize — reference `Air.outer_step`, `project`, `residuals`, `solve`,
//! `finalize` (`air.py`) with the second-order advection correction off.

use crate::case::{Consts, Criterion};
use crate::kernels::{HeatIn, MomIn, Vel, apply_bc, build_all_mom, build_heat, kloc};
use crate::lines::{Scratch, resid, sweep};
use crate::mg::Mg;
use crate::util::{Row, det_sum, par_max};
use rayon::prelude::*;
use std::time::Instant;

/// Prognostic fields (halo arrays) and the two eddy viscosities.
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

/// Outcome of [`Picard::solve`].
pub struct SolveOut {
    /// `"ok"`, `"max"` or `"diverged"`.
    pub status: &'static str,
    /// Iteration number of the last check.
    pub iters: usize,
    pub history: Vec<Check>,
    /// Seconds spent in iterations (checks excluded) and in checks.
    pub iter_s: f64,
    pub check_s: f64,
    pub n_checks: usize,
    /// Total seconds per phase of the iteration (checks excluded), order
    /// `[mom, heat, proj, kupd, other]`; sums to `iter_s`.
    pub phase_s: [f64; 5],
}

/// The iteration: constants, fields, multigrid and work buffers.
pub struct Picard {
    pub k: Consts,
    pub f: Fields,
    pub mg: Mg,
    pub cu: Vec<Row>,
    pub cv: Vec<Row>,
    pub cw: Vec<Row>,
    pub ct: Vec<Row>,
    pub ctd: Vec<Row>,
    pub qeff: Vec<f32>,
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
        let zr = || vec![[0.0f32; 8]; n];
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
            qeff: z(),
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
    /// All passes are row-wise in the rayon pool; the halo copy of `phi` writes only the
    /// interior of `pfull` (its halo cells are zero from allocation and never written).
    pub fn project(&mut self, cycles: usize, update_p: bool) {
        let k = &self.k;
        let nx = k.nx;
        Self::divergence(k, &self.f.u, &self.f.v, &self.f.w, &mut self.div);
        let fi = &self.fluid_int;
        let mean = (det_sum(self.div.len(), |q| f64::from(self.div[q])) / k.n_fluid) as f32;
        self.div
            .par_chunks_mut(nx)
            .zip(fi.par_chunks(nx))
            .for_each(|(d, f)| {
                for (d, &f) in d.iter_mut().zip(f) {
                    *d -= mean * f;
                }
            });
        self.mg.set_rhs(&self.div);
        self.mg.zero_phi();
        for _ in 0..cycles {
            self.mg.vcycle();
        }
        let phi = self.mg.phi_mut();
        let pm = (det_sum(phi.len(), |q| f64::from(phi[q] * fi[q])) / k.n_fluid) as f32;
        phi.par_chunks_mut(nx)
            .zip(fi.par_chunks(nx))
            .for_each(|(x, f)| {
                for (x, &f) in x.iter_mut().zip(f) {
                    *x -= pm * f;
                }
            });
        let phi = self.mg.phi();
        let (nxh, nyh, ny) = (k.nxh, k.nyh, k.ny);
        self.pfull
            .par_chunks_mut(nxh)
            .enumerate()
            .for_each(|(hr, row)| {
                let (kk, j) = (hr / nyh, hr % nyh);
                if (1..=k.nz).contains(&kk) && (1..=ny).contains(&j) {
                    let r = (kk - 1) * ny + (j - 1);
                    row[1..=nx].copy_from_slice(&phi[r * nx..(r + 1) * nx]);
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
        self.qeff
            .par_iter_mut()
            .zip(k.q.par_iter().zip(f.thd.par_iter()))
            .for_each(|(e, (&q, &d))| *e = q - d * k.inv_tau);
        let h = HeatIn {
            vel: Vel {
                u: &f.u,
                v: &f.v,
                w: &f.w,
            },
            x: &f.th,
            q: &self.qeff,
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

    /// Final projection to near-exact divergence without changing `p` (`cycles` V-cycles).
    pub fn finalize(&mut self, cycles: usize) {
        apply_bc(&self.k, &mut self.f.u, &mut self.f.v);
        self.project(cycles, false);
    }

    /// Runs the iteration from the cold start until the criterion, `max_iters` or divergence
    /// (reference `solve`; the first check happens after `check_every` iterations).
    pub fn solve(&mut self, crit: &Criterion, max_iters: usize) -> SolveOut {
        if self.k.no_thd {
            self.f.thd.fill(0.0);
        }
        let mut hist = Vec::new();
        let mut status = "max";
        let (mut iter_s, mut check_s) = (0.0, 0.0);
        let mut it = crit.pre_steps;
        let ph0 = self.phase;
        let tp = Instant::now();
        let t_start = tp;
        for _ in 0..crit.pre_steps {
            self.outer_step();
        }
        iter_s += tp.elapsed().as_secs_f64();
        while it < max_iters {
            let t0 = Instant::now();
            for _ in 0..crit.check_every {
                self.outer_step();
            }
            it += crit.check_every;
            iter_s += t0.elapsed().as_secs_f64();
            let t1 = Instant::now();
            let r = self.residuals();
            check_s += t1.elapsed().as_secs_f64();
            hist.push(Check {
                it,
                res: r,
                t_s: t_start.elapsed().as_secs_f64(),
            });
            let finite = [r.mom_max, r.mom_rms, r.th_rms, r.div_rms]
                .iter()
                .all(|x| x.is_finite());
            if !finite || r.mom_max > 50.0 {
                status = "diverged";
                break;
            }
            if r.mom_rms < crit.tol_mom_rms
                && r.th_rms < crit.tol_th_rms
                && r.div_rms < crit.tol_div_rms
            {
                status = "ok";
                break;
            }
        }
        let mut phase_s = [0.0; 5];
        for i in 0..4 {
            phase_s[i] = self.phase[i] - ph0[i];
        }
        phase_s[4] = (iter_s - phase_s[..4].iter().sum::<f64>()).max(0.0);
        SolveOut {
            status,
            iters: it,
            n_checks: hist.len(),
            history: hist,
            iter_s,
            check_s,
            phase_s,
        }
    }
}
