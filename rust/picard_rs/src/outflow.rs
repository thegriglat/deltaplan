//! OB1 v1 (`docs/contracts/outflow-bc.md`): soft outflow of the lateral boundary.
//!
//! The faces of type 2 of `u`, `v` on the lateral boundary whose outward normal `s` has
//! `s * ubg > 0` (where the hard condition fixes `ubg * c`) take the value of the neighbouring
//! inner face of the same component (zero normal gradient). The net flux through all type-2
//! faces is then removed evenly from the outflow faces (`u <- u - s S / N_out`), so the
//! projection sees a balanced boundary. The tangential components in the halo columns behind an
//! outflow face (`v`, `w` behind an x face; `u`, `w` behind a y face; type-3 faces only) take
//! the value of the neighbouring inner node. Without this struct in [`crate::solver::Picard`]
//! nothing changes (the hard condition).

use crate::case::Consts;
use anyhow::{Result, bail};
use std::collections::BTreeMap;

/// One type-2 face on the lateral boundary.
struct Face {
    idx: usize,
    /// 0 = `u`, 1 = `v`.
    comp: u8,
    /// Outward normal along the array axis, -1 or +1.
    s: f64,
    out: bool,
    /// Inner neighbour face of the same component when it is an air face (type 1).
    inner: Option<usize>,
    /// Position in `fixed_u` / `fixed_v`.
    q: usize,
}

/// One halo node that takes the value of its inner neighbour(s).
struct Ring {
    target: usize,
    src: [usize; 2],
    n: u8,
    /// 0 = `u`, 1 = `v`, 2 = `w`.
    comp: u8,
}

/// Soft outflow state of one solver.
pub struct SoftOutflow {
    faces: Vec<Face>,
    ring: Vec<Ring>,
    tmp: Vec<f32>,
    pub faces_out: usize,
    pub flux_in: f64,
    /// Max over all applications of `|S| / flux_in` after the correction.
    pub flux_net_max_rel: f64,
}

/// Diagnostics of a soft run (`Solved.outflow`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OutflowDiag {
    /// Outflow faces (`u` and `v` together).
    pub faces_out: usize,
    /// `sum |s u|` over the inflow faces, m/s.
    pub flux_in: f64,
    /// Max over the applications of `|sum_all s u| / flux_in` after the correction.
    pub flux_net_max_rel: f64,
    /// Outflow faces with `s u < 0` in the delivered field.
    pub backflow_faces: usize,
}

fn side(i: usize, n: usize) -> f64 {
    if i == 1 {
        -1.0
    } else if i + 1 == n {
        1.0
    } else {
        0.0
    }
}

impl SoftOutflow {
    /// Builds the face lists of `k`. A window (`nest`) is an error; a calm case
    /// (`u10_positive == false`) gives an inactive (hard) state.
    pub fn new(k: &Consts) -> Result<Self> {
        if k.nest.is_some() {
            bail!("soft outflow: a case with a nest (window) is not supported (OB1 v1)");
        }
        let mut sf = Self {
            faces: Vec::new(),
            ring: Vec::new(),
            tmp: Vec::new(),
            faces_out: 0,
            flux_in: 0.0,
            flux_net_max_rel: 0.0,
        };
        if !k.u10_positive {
            return Ok(sf);
        }
        let (nxh, nyh, nzh) = (k.nxh, k.nyh, k.nzh);
        for (q, &idx) in k.b_u.iter().enumerate() {
            let s = side(idx % nxh, nxh);
            if s == 0.0 {
                continue;
            }
            let inner = (idx as isize - s as isize) as usize;
            sf.faces.push(Face {
                idx,
                comp: 0,
                s,
                out: s * f64::from(k.ubg[idx]) > 0.0,
                inner: (k.tu[inner] == 1).then_some(inner),
                q,
            });
        }
        for (q, &idx) in k.b_v.iter().enumerate() {
            let s = side((idx / nxh) % nyh, nyh);
            if s == 0.0 {
                continue;
            }
            let inner = (idx as isize - s as isize * nxh as isize) as usize;
            sf.faces.push(Face {
                idx,
                comp: 1,
                s,
                out: s * f64::from(k.vbg[idx]) > 0.0,
                inner: (k.tv[inner] == 1).then_some(inner),
                q,
            });
        }
        sf.faces_out = sf.faces.iter().filter(|f| f.out).count();
        sf.flux_in = sf
            .faces
            .iter()
            .filter(|f| {
                !f.out
                    && f.s
                        * f64::from(if f.comp == 0 {
                            k.ubg[f.idx]
                        } else {
                            k.vbg[f.idx]
                        })
                        < 0.0
            })
            .map(|f| {
                f64::from(if f.comp == 0 {
                    k.fixed_u[f.q]
                } else {
                    k.fixed_v[f.q]
                })
                .abs()
            })
            .sum();
        // Halo columns behind the outflow faces; a node behind two sides (corner) takes the mean.
        let has = |comp: u8, s: f64| sf.faces.iter().any(|f| f.out && f.comp == comp && f.s == s);
        let mut m: BTreeMap<(u8, usize), Vec<usize>> = BTreeMap::new();
        for s in [-1.0, 1.0] {
            if has(0, s) {
                let (cx, ci) = if s < 0.0 { (0, 1) } else { (nxh - 1, nxh - 2) };
                for kk in 0..nzh {
                    for j in 0..nyh {
                        let t = (kk * nyh + j) * nxh + cx;
                        let sr = (kk * nyh + j) * nxh + ci;
                        if k.tv[t] == 3 {
                            m.entry((1, t)).or_default().push(sr);
                        }
                        if k.tw[t] == 3 {
                            m.entry((2, t)).or_default().push(sr);
                        }
                    }
                }
            }
            if has(1, s) {
                let (cy, cj) = if s < 0.0 { (0, 1) } else { (nyh - 1, nyh - 2) };
                for kk in 0..nzh {
                    for i in 0..nxh {
                        let t = (kk * nyh + cy) * nxh + i;
                        let sr = (kk * nyh + cj) * nxh + i;
                        if k.tu[t] == 3 {
                            m.entry((0, t)).or_default().push(sr);
                        }
                        if k.tw[t] == 3 {
                            m.entry((2, t)).or_default().push(sr);
                        }
                    }
                }
            }
        }
        for ((comp, target), v) in m {
            sf.ring.push(Ring {
                target,
                src: [v[0], v.get(1).copied().unwrap_or(v[0])],
                n: v.len() as u8,
                comp,
            });
        }
        sf.tmp = vec![0.0; sf.ring.len()];
        Ok(sf)
    }

    fn net(&self, u: &[f32], v: &[f32]) -> f64 {
        let mut s = 0.0f64;
        for f in &self.faces {
            let x = if f.comp == 0 { u[f.idx] } else { v[f.idx] };
            s += f.s * f64::from(x);
        }
        s
    }

    /// Applies the soft condition on top of the hard one (`apply_bc` has set every type-2 face
    /// to `fixed`). Sequential in face order, so the result does not depend on the threads.
    pub fn apply(&mut self, k: &Consts, u: &mut [f32], v: &mut [f32], w: &mut [f32]) {
        if self.faces_out == 0 {
            return;
        }
        for f in self.faces.iter().filter(|f| f.out) {
            let (a, fx) = if f.comp == 0 {
                (&mut *u, &k.fixed_u)
            } else {
                (&mut *v, &k.fixed_v)
            };
            a[f.idx] = f.inner.map_or(fx[f.q], |i| a[i]);
        }
        let corr = self.net(u, v) / self.faces_out as f64;
        for f in self.faces.iter().filter(|f| f.out) {
            let a = if f.comp == 0 { &mut *u } else { &mut *v };
            a[f.idx] = (f64::from(a[f.idx]) - f.s * corr) as f32;
        }
        if self.flux_in > 0.0 {
            let rel = self.net(u, v).abs() / self.flux_in;
            self.flux_net_max_rel = self.flux_net_max_rel.max(rel);
        }
        for (t, r) in self.tmp.iter_mut().zip(&self.ring) {
            let a = match r.comp {
                0 => &*u,
                1 => &*v,
                _ => &*w,
            };
            *t = if r.n == 2 {
                0.5 * (a[r.src[0]] + a[r.src[1]])
            } else {
                a[r.src[0]]
            };
        }
        for (t, r) in self.tmp.iter().zip(&self.ring) {
            let a = match r.comp {
                0 => &mut *u,
                1 => &mut *v,
                _ => &mut *w,
            };
            a[r.target] = *t;
        }
    }

    /// Diagnostics for the delivered `u`, `v`.
    pub fn diag(&self, u: &[f32], v: &[f32]) -> OutflowDiag {
        let backflow_faces = self
            .faces
            .iter()
            .filter(|f| {
                f.out && f.s * f64::from(if f.comp == 0 { u[f.idx] } else { v[f.idx] }) < 0.0
            })
            .count();
        OutflowDiag {
            faces_out: self.faces_out,
            flux_in: self.flux_in,
            flux_net_max_rel: self.flux_net_max_rel,
            backflow_faces,
        }
    }
}
