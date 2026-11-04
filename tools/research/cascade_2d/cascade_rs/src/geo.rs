//! Geometry of one level of the slice: cell, face types, ground height and heat source.
//!
//! Nesting (F0): x faces of level n are the even x faces of level n+1; z faces of level n are the
//! odd z faces of level n+1 (`z0 = -dz` on every level, so the lowest parent face has no child
//! counterpart). Child row of parent row `K`, half `s`: `2K + s - 1`; child z face of parent z
//! face `K`: `2K - 1`; child z face inside parent row `K`: `2K`.

use anyhow::{Result, bail};

#[derive(Clone, Debug)]
pub struct Geo {
    pub nx: usize,
    pub nz: usize,
    pub dx: f64,
    pub dz: f64,
    pub z0: f64,
    /// 1 air, 0 ground; (nz, nx).
    pub cell: Vec<u8>,
    /// Type of x faces, (nz, nx + 1); 0 wall, >= 1 open.
    pub tu: Vec<u8>,
    /// Type of z faces, (nz + 1, nx).
    pub tw: Vec<u8>,
    /// Ground height by column, (nx).
    pub h: Vec<f32>,
    /// Heat source of the cells (K/s), (nz, nx).
    pub q: Vec<f32>,
    /// Background potential-temperature gradient d(theta_bar)/dz per row, K/m (R1 `gam`).
    pub gam: Vec<f64>,
}

impl Geo {
    pub fn air(&self, k: i64, i: i64) -> bool {
        k >= 0
            && i >= 0
            && (k as usize) < self.nz
            && (i as usize) < self.nx
            && self.cell[k as usize * self.nx + i as usize] != 0
    }

    pub fn q_at(&self, k: i64, i: i64) -> f64 {
        self.q[k as usize * self.nx + i as usize] as f64
    }

    /// x face `(k, i)` carries flux: open type and every existing neighbour cell is air.
    pub fn u_open(&self, k: i64, i: i64) -> bool {
        if k < 0 || k >= self.nz as i64 || i < 0 || i > self.nx as i64 {
            return false;
        }
        self.tu[k as usize * (self.nx + 1) + i as usize] > 0
            && (i == 0 || self.air(k, i - 1))
            && (i == self.nx as i64 || self.air(k, i))
    }

    /// z face `(k, i)` carries flux (same rule).
    pub fn w_open(&self, k: i64, i: i64) -> bool {
        if k < 0 || k > self.nz as i64 || i < 0 || i >= self.nx as i64 {
            return false;
        }
        self.tw[k as usize * self.nx + i as usize] > 0
            && (k == 0 || self.air(k - 1, i))
            && (k == self.nz as i64 || self.air(k, i))
    }

    /// Geometry of the child level that only repeats the parent (no terrain knowledge): each
    /// child cell takes the type of its parent cell, outer sub-faces the type of the parent face,
    /// inner faces are open inside an air parent.
    pub fn inherit(&self) -> Geo {
        let (nx, nz) = (2 * self.nx, 2 * self.nz - 1);
        let par_k = |r: usize| r.div_ceil(2); // parent row of child row r
        let mut cell = vec![0u8; nz * nx];
        let mut tu = vec![0u8; nz * (nx + 1)];
        let mut tw = vec![0u8; (nz + 1) * nx];
        for r in 0..nz {
            let kp = par_k(r);
            for i in 0..nx {
                cell[r * nx + i] = self.cell[kp * self.nx + i / 2];
            }
            for i in 0..=nx {
                tu[r * (nx + 1) + i] = if i % 2 == 0 {
                    self.tu[kp * (self.nx + 1) + i / 2]
                } else {
                    u8::from(self.cell[kp * self.nx + i / 2] != 0)
                };
            }
        }
        for f in 0..=nz {
            for i in 0..nx {
                let ip = i / 2;
                tw[f * nx + i] = if f % 2 == 1 {
                    self.tw[f.div_ceil(2) * self.nx + ip]
                } else {
                    let kp = f / 2;
                    u8::from(kp < self.nz && self.cell[kp * self.nx + ip] != 0)
                };
            }
        }
        // The bottom boundary of the child domain stays a wall (no child under parent row 0).
        tw[..nx].fill(0);
        let h = (0..nx).map(|i| self.h[i / 2]).collect();
        Geo {
            nx,
            nz,
            dx: self.dx / 2.0,
            dz: self.dz / 2.0,
            z0: -self.dz / 2.0,
            cell,
            tu,
            tw,
            h,
            q: vec![0.0; nz * nx],
            gam: (0..nz).map(|r| self.gam[par_k(r)]).collect(),
        }
    }

    /// Keeps the lowest `nz` rows (the nested part of the parent domain).
    pub fn crop_rows(&mut self, nz: usize) -> Result<()> {
        if self.nz < nz {
            bail!("geometry has {} rows, nested child needs {nz}", self.nz);
        }
        self.cell.truncate(nz * self.nx);
        self.q.truncate(nz * self.nx);
        self.gam.truncate(nz);
        self.tu.truncate(nz * (self.nx + 1));
        self.tw.truncate((nz + 1) * self.nx);
        self.nz = nz;
        Ok(())
    }
}
