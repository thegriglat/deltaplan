//! A level of the cascade: whole-field descent step and the lazy (point-by-point) level.

use crate::rules::{Ctx, Internal, Src};
use rayon::prelude::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};
use std::rc::Rc;

/// Fields of one level (F1 layout): u (nz, nx+1), w (nz+1, nx), th (nz, nx).
#[derive(Clone)]
pub struct Level {
    pub nx: usize,
    pub nz: usize,
    pub u: Vec<f32>,
    pub w: Vec<f32>,
    pub th: Vec<f32>,
}

impl Src for Level {
    fn u(&self, k: usize, i: usize) -> f32 {
        self.u[k * (self.nx + 1) + i]
    }
    fn w(&self, k: usize, i: usize) -> f32 {
        self.w[k * self.nx + i]
    }
    fn th(&self, k: usize, i: usize) -> f32 {
        self.th[k * self.nx + i]
    }
}

struct Row {
    xs: Vec<(f32, f32)>,
    zs: Vec<(f32, f32)>,
    int: Vec<Internal>,
    th: Vec<[f32; 4]>,
}

/// Whole-field step: parent level -> child level. Deterministic for any thread count (the work
/// of a row does not depend on other rows; rows are assembled in order).
pub fn step_full(ctx: &Ctx, src: &Level) -> Level {
    let (nx, nz) = (src.nx, src.nz);
    let (cnx, cnz) = (2 * nx, 2 * nz - 1);
    let rows: Vec<Row> = (0..=nz)
        .into_par_iter()
        .map(|k| {
            let zs = (0..nx).map(|i| ctx.split_z_d(src, k, i, true)).collect();
            if k == nz {
                return Row {
                    xs: vec![],
                    zs,
                    int: vec![],
                    th: vec![],
                };
            }
            Row {
                xs: (0..=nx).map(|i| ctx.split_x_d(src, k, i, true)).collect(),
                zs,
                int: (0..nx).map(|i| ctx.internal_d(src, k, i, true)).collect(),
                th: (0..nx)
                    .map(|i| {
                        [
                            ctx.child_th(src, k, i, 0, 0),
                            ctx.child_th(src, k, i, 0, 1),
                            ctx.child_th(src, k, i, 1, 0),
                            ctx.child_th(src, k, i, 1, 1),
                        ]
                    })
                    .collect(),
            }
        })
        .collect();
    let mut out = Level {
        nx: cnx,
        nz: cnz,
        u: vec![0.0; cnz * (cnx + 1)],
        w: vec![0.0; (cnz + 1) * cnx],
        th: vec![0.0; cnz * cnx],
    };
    for (k, row) in rows.iter().enumerate() {
        if k >= 1 {
            let f = 2 * k - 1;
            for (i, &(l, r)) in row.zs.iter().enumerate() {
                out.w[f * cnx + 2 * i] = l;
                out.w[f * cnx + 2 * i + 1] = r;
            }
        }
        if k == nz {
            continue;
        }
        for (i, &(lo, hi)) in row.xs.iter().enumerate() {
            for (s, v) in [(0usize, lo), (1, hi)] {
                let r = Ctx::crow(k, s);
                if r >= 0 {
                    out.u[r as usize * (cnx + 1) + 2 * i] = v;
                }
            }
        }
        for (i, it) in row.int.iter().enumerate() {
            for (s, v) in [(0usize, it.ub), (1, it.ut)] {
                let r = Ctx::crow(k, s);
                if r >= 0 {
                    out.u[r as usize * (cnx + 1) + 2 * i + 1] = v;
                }
            }
            out.w[2 * k * cnx + 2 * i] = it.wl;
            out.w[2 * k * cnx + 2 * i + 1] = it.wr;
        }
        for (i, t) in row.th.iter().enumerate() {
            for s in 0..2 {
                let r = Ctx::crow(k, s);
                if r < 0 {
                    continue;
                }
                for c in 0..2 {
                    out.th[r as usize * cnx + 2 * i + c] = t[s * 2 + c];
                }
            }
        }
    }
    out
}

// ---- lazy level (point-by-point) --------------------------------------------------------------

#[derive(Default)]
struct Fx(u64);

impl Hasher for Fx {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0.rotate_left(5) ^ b as u64).wrapping_mul(0x517c_c1b7_2722_0a95);
        }
    }
    fn write_u64(&mut self, v: u64) {
        self.0 = (self.0.rotate_left(5) ^ v).wrapping_mul(0x517c_c1b7_2722_0a95);
    }
}

type Map<V> = RefCell<HashMap<u64, V, BuildHasherDefault<Fx>>>;

fn key(k: usize, i: usize) -> u64 {
    ((k as u64) << 32) | i as u64
}

/// Child level computed on demand from the parent level with memoisation; no state beyond the
/// caches. Uses the same rule functions as [`step_full`], hence the same bits.
pub struct Lazy {
    ctx: Ctx,
    parent: Rc<dyn Src>,
    sx: Map<(f32, f32)>,
    sz: Map<(f32, f32)>,
    cell: Map<Internal>,
    th: Map<f32>,
}

impl Lazy {
    pub fn new(ctx: Ctx, parent: Rc<dyn Src>) -> Self {
        Lazy {
            ctx,
            parent,
            sx: Default::default(),
            sz: Default::default(),
            cell: Default::default(),
            th: Default::default(),
        }
    }

    fn internal(&self, k: usize, i: usize) -> Internal {
        if let Some(v) = self.cell.borrow().get(&key(k, i)) {
            return *v;
        }
        // The cell solve reads the parent through its own splits; compute outside the borrow.
        let v = self.ctx.internal(self.parent.as_ref(), k, i);
        self.cell.borrow_mut().insert(key(k, i), v);
        v
    }
}

impl Src for Lazy {
    fn u(&self, r: usize, i: usize) -> f32 {
        let (k, s) = (r.div_ceil(2), (r + 1) % 2);
        if i.is_multiple_of(2) {
            let (lo, hi) = self.split_x(k, i / 2);
            if s == 0 { lo } else { hi }
        } else {
            let it = self.internal(k, i / 2);
            if s == 0 { it.ub } else { it.ut }
        }
    }
    fn w(&self, f: usize, i: usize) -> f32 {
        let c = i % 2;
        if f % 2 == 1 {
            let (l, r) = self.split_z(f.div_ceil(2), i / 2);
            if c == 0 { l } else { r }
        } else {
            let it = self.internal(f / 2, i / 2);
            if c == 0 { it.wl } else { it.wr }
        }
    }
    fn th(&self, r: usize, i: usize) -> f32 {
        let (k, s) = (r.div_ceil(2), (r + 1) % 2);
        let kk = key(r, i);
        if let Some(v) = self.th.borrow().get(&kk) {
            return *v;
        }
        let v = self.ctx.child_th(self.parent.as_ref(), k, i / 2, s, i % 2);
        self.th.borrow_mut().insert(kk, v);
        v
    }
}

impl Lazy {
    fn split_x(&self, k: usize, i: usize) -> (f32, f32) {
        if let Some(v) = self.sx.borrow().get(&key(k, i)) {
            return *v;
        }
        let v = self.ctx.split_x(self.parent.as_ref(), k, i);
        self.sx.borrow_mut().insert(key(k, i), v);
        v
    }
    fn split_z(&self, k: usize, i: usize) -> (f32, f32) {
        if let Some(v) = self.sz.borrow().get(&key(k, i)) {
            return *v;
        }
        let v = self.ctx.split_z(self.parent.as_ref(), k, i);
        self.sz.borrow_mut().insert(key(k, i), v);
        v
    }
}
