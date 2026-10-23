//! Geometric multigrid V-cycle for the pressure-correction equation `div(K grad phi) = f`
//! (reference class `MG`): coarsening by 2 in x, y only, vertical zebra line smoother.

use crate::lines::{Scratch, Shape, resid, sweep};
use crate::util::{RHS, Row};
use rayon::prelude::*;

/// One grid level (no halo): stencil rows (the `b` slot holds the right-hand side),
/// activity mask, current solution and residual buffers.
pub struct Level {
    shape: Shape,
    rows: Vec<Row>,
    act: Vec<f32>,
    x: Vec<f32>,
    r: Vec<f32>,
    sc: Scratch,
}

/// The multigrid hierarchy of one case.
pub struct Mg {
    levels: Vec<Level>,
}

/// Face conductances and activity of one level, `f64`.
struct Faces {
    nz: usize,
    ny: usize,
    nx: usize,
    cx: Vec<f64>, // (nz, ny, nx + 1)
    cy: Vec<f64>, // (nz, ny + 1, nx)
    cz: Vec<f64>, // (nz + 1, ny, nx)
    active: Vec<bool>,
}

impl Faces {
    fn ix(&self, k: usize, j: usize, i: usize) -> usize {
        (k * self.ny + j) * (self.nx + 1) + i
    }
    fn iy(&self, k: usize, j: usize, i: usize) -> usize {
        (k * (self.ny + 1) + j) * self.nx + i
    }
    fn iz(&self, k: usize, j: usize, i: usize) -> usize {
        (k * self.ny + j) * self.nx + i
    }
    fn ic(&self, k: usize, j: usize, i: usize) -> usize {
        (k * self.ny + j) * self.nx + i
    }

    /// 7-point stencil rows (`b` = 0); dead cells get the identity row.
    fn stencil(&self) -> Vec<Row> {
        let (nz, ny, nx) = (self.nz, self.ny, self.nx);
        let mut rows = vec![[0.0f32; 8]; nz * ny * nx];
        for k in 0..nz {
            for j in 0..ny {
                for i in 0..nx {
                    let mut c = [0.0f64; 7];
                    c[1] = self.cx[self.ix(k, j, i)];
                    c[2] = self.cx[self.ix(k, j, i + 1)];
                    c[3] = self.cy[self.iy(k, j, i)];
                    c[4] = self.cy[self.iy(k, j + 1, i)];
                    c[5] = self.cz[self.iz(k, j, i)];
                    c[6] = self.cz[self.iz(k + 1, j, i)];
                    c[0] = -(c[1] + c[2] + c[3] + c[4] + c[5] + c[6]);
                    if i == 0 {
                        c[1] = 0.0;
                    }
                    if i == nx - 1 {
                        c[2] = 0.0;
                    }
                    if j == 0 {
                        c[3] = 0.0;
                    }
                    if j == ny - 1 {
                        c[4] = 0.0;
                    }
                    if k == 0 {
                        c[5] = 0.0;
                    }
                    if k == nz - 1 {
                        c[6] = 0.0;
                    }
                    let q = self.ic(k, j, i);
                    let dead = !self.active[q] || c[0] == 0.0;
                    let r = &mut rows[q];
                    if dead {
                        r[0] = 1.0;
                    } else {
                        for o in 0..7 {
                            r[o] = c[o] as f32;
                        }
                    }
                }
            }
        }
        rows
    }

    /// Coarsens by 2 in x, y (conductance of a coarse face: sum / 8, z: sum / 4), then
    /// closes faces next to inactive coarse cells.
    fn coarsen(&self) -> Faces {
        let (nz, ny, nx) = (self.nz, self.ny / 2, self.nx / 2);
        let mut c = Faces {
            nz,
            ny,
            nx,
            cx: vec![0.0; nz * ny * (nx + 1)],
            cy: vec![0.0; nz * (ny + 1) * nx],
            cz: vec![0.0; (nz + 1) * ny * nx],
            active: vec![false; nz * ny * nx],
        };
        for k in 0..nz {
            for j in 0..ny {
                for i in 0..nx {
                    let mut a = false;
                    for dj in 0..2 {
                        for di in 0..2 {
                            a |= self.active[self.ic(k, 2 * j + dj, 2 * i + di)];
                        }
                    }
                    let q = c.ic(k, j, i);
                    c.active[q] = a;
                }
            }
        }
        for k in 0..nz {
            for j in 0..ny {
                for i in 0..=nx {
                    let v = (self.cx[self.ix(k, 2 * j, 2 * i)]
                        + self.cx[self.ix(k, 2 * j + 1, 2 * i)])
                        / 8.0;
                    let open = if i == 0 {
                        c.active[c.ic(k, j, 0)]
                    } else if i == nx {
                        c.active[c.ic(k, j, nx - 1)]
                    } else {
                        c.active[c.ic(k, j, i)] && c.active[c.ic(k, j, i - 1)]
                    };
                    let q = c.ix(k, j, i);
                    c.cx[q] = if open { v } else { 0.0 };
                }
            }
        }
        for k in 0..nz {
            for j in 0..=ny {
                for i in 0..nx {
                    let v = (self.cy[self.iy(k, 2 * j, 2 * i)]
                        + self.cy[self.iy(k, 2 * j, 2 * i + 1)])
                        / 8.0;
                    let open = if j == 0 {
                        c.active[c.ic(k, 0, i)]
                    } else if j == ny {
                        c.active[c.ic(k, ny - 1, i)]
                    } else {
                        c.active[c.ic(k, j, i)] && c.active[c.ic(k, j - 1, i)]
                    };
                    let q = c.iy(k, j, i);
                    c.cy[q] = if open { v } else { 0.0 };
                }
            }
        }
        for k in 0..=nz {
            for j in 0..ny {
                for i in 0..nx {
                    let v = (self.cz[self.iz(k, 2 * j, 2 * i)]
                        + self.cz[self.iz(k, 2 * j, 2 * i + 1)]
                        + self.cz[self.iz(k, 2 * j + 1, 2 * i)]
                        + self.cz[self.iz(k, 2 * j + 1, 2 * i + 1)])
                        / 4.0;
                    let open = if k == 0 {
                        c.active[c.ic(0, j, i)]
                    } else if k == nz {
                        c.active[c.ic(nz - 1, j, i)]
                    } else {
                        c.active[c.ic(k, j, i)] && c.active[c.ic(k - 1, j, i)]
                    };
                    let q = c.iz(k, j, i);
                    c.cz[q] = if open { v } else { 0.0 };
                }
            }
        }
        c
    }
}

impl Mg {
    /// Builds the hierarchy from the projection conductivities `kx, ky, kz` (halo arrays of
    /// shape `(nzh, nyh, nxh)`), the air mask `fluid` (halo array) and the cell sizes.
    pub fn new(
        kx: &[f32],
        ky: &[f32],
        kz: &[f32],
        fluid: &[f32],
        dims: Shape,
        dx: f32,
        dz: f32,
    ) -> Self {
        let (nzh, nyh, nxh) = dims;
        let (nz, ny, nx) = (nzh - 2, nyh - 2, nxh - 2);
        let h = |k: usize, j: usize, i: usize| (k * nyh + j) * nxh + i;
        let (dx2, dz2) = (f64::from(dx) * f64::from(dx), f64::from(dz) * f64::from(dz));
        let mut f = Faces {
            nz,
            ny,
            nx,
            cx: vec![0.0; nz * ny * (nx + 1)],
            cy: vec![0.0; nz * (ny + 1) * nx],
            cz: vec![0.0; (nz + 1) * ny * nx],
            active: vec![false; nz * ny * nx],
        };
        for k in 0..nz {
            for j in 0..ny {
                for i in 0..=nx {
                    let q = f.ix(k, j, i);
                    f.cx[q] = f64::from(kx[h(k + 1, j + 1, i + 1)]) / dx2;
                }
            }
        }
        for k in 0..nz {
            for j in 0..=ny {
                for i in 0..nx {
                    let q = f.iy(k, j, i);
                    f.cy[q] = f64::from(ky[h(k + 1, j + 1, i + 1)]) / dx2;
                }
            }
        }
        for k in 0..=nz {
            for j in 0..ny {
                for i in 0..nx {
                    let q = f.iz(k, j, i);
                    f.cz[q] = f64::from(kz[h(k + 1, j + 1, i + 1)]) / dz2;
                }
            }
        }
        for k in 0..nz {
            for j in 0..ny {
                for i in 0..nx {
                    let q = f.ic(k, j, i);
                    f.active[q] = fluid[h(k + 1, j + 1, i + 1)] != 0.0;
                }
            }
        }
        let mut levels = Vec::new();
        loop {
            let n = f.nz * f.ny * f.nx;
            levels.push(Level {
                shape: (f.nz, f.ny, f.nx),
                rows: f.stencil(),
                act: f.active.iter().map(|&a| f32::from(a)).collect(),
                x: vec![0.0; n],
                r: vec![0.0; n],
                sc: Scratch::new(n),
            });
            if !f.nx.is_multiple_of(2) || !f.ny.is_multiple_of(2) || f.nx < 6 || f.ny < 6 {
                break;
            }
            f = f.coarsen();
        }
        Self { levels }
    }

    /// Grid sizes `(nx, ny, nz)` of every level.
    pub fn level_dims(&self) -> Vec<[usize; 3]> {
        self.levels
            .iter()
            .map(|l| [l.shape.2, l.shape.1, l.shape.0])
            .collect()
    }

    /// Finest-level solution `phi` (no halo).
    pub fn phi(&self) -> &[f32] {
        &self.levels[0].x
    }

    /// Mutable finest-level solution.
    pub fn phi_mut(&mut self) -> &mut [f32] {
        &mut self.levels[0].x
    }

    /// Sets the finest-level right-hand side.
    pub fn set_rhs(&mut self, f: &[f32]) {
        for (r, &v) in self.levels[0].rows.iter_mut().zip(f) {
            r[RHS] = v;
        }
    }

    /// One V-cycle on the finest level (2 pre, 2 post smoothing sweeps in z, 20 sweeps of
    /// (z, x, y) on the coarsest level), updating `phi` in place.
    pub fn vcycle(&mut self) {
        vcycle_rec(&mut self.levels);
    }
}

fn vcycle_rec(levels: &mut [Level]) {
    let (cur, rest) = levels.split_at_mut(1);
    let l = &mut cur[0];
    if rest.is_empty() {
        for _ in 0..20 {
            sweep(&l.rows, &mut l.x, &mut l.sc, l.shape, &[2, 0, 1]);
        }
        return;
    }
    for _ in 0..2 {
        sweep(&l.rows, &mut l.x, &mut l.sc, l.shape, &[2]);
    }
    resid(&l.rows, &l.x, l.shape, &mut l.r);
    let (_, ny, nx) = l.shape;
    let (cny, cnx) = (ny / 2, nx / 2);
    let c = &mut rest[0];
    {
        let r = &l.r;
        c.rows
            .par_iter_mut()
            .zip(c.x.par_iter_mut())
            .enumerate()
            .for_each(|(q, (row, xc))| {
                let i = q % cnx;
                let j = (q / cnx) % cny;
                let k = q / (cnx * cny);
                let mut s = 0.0f32;
                for dj in 0..2 {
                    for di in 0..2 {
                        s += r[(k * ny + 2 * j + dj) * nx + 2 * i + di];
                    }
                }
                row[RHS] = s / 4.0 * c.act[q];
                *xc = 0.0;
            });
    }
    vcycle_rec(rest);
    let c = &rest[0];
    let act = &l.act;
    l.x.par_iter_mut().enumerate().for_each(|(q, x)| {
        let i = q % nx;
        let j = (q / nx) % ny;
        let k = q / (nx * ny);
        *x += c.x[(k * cny + j / 2) * cnx + i / 2] * act[q];
    });
    for _ in 0..2 {
        sweep(&l.rows, &mut l.x, &mut l.sc, l.shape, &[2]);
    }
}
