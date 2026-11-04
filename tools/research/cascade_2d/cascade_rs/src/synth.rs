//! Synthetic geometries and divergence-free parent fields (selftest, tests, demonstration).
//!
//! The terrain of level n is the upper envelope of the 25 m columns (maximum over the columns
//! inside), so a coarse air cell never has all of its children in the ground, and the geometry
//! is consistent between levels.

use crate::geo::Geo;
use crate::level::Level;
use crate::util::Rng;

pub const NZ0: usize = 26;

/// (height, half width) of the Agnesi hill of a case.
pub fn hill(case: &str) -> (f64, f64) {
    match case {
        "C0" => (0.0, 1.0),
        "C2" => (250.0, 300.0),
        _ => (200.0, 500.0),
    }
}

/// Geometry of level `n` (dx = 400/2^n) of a synthetic case.
pub fn geo(case: &str, n: usize, heated: bool) -> Geo {
    let (hh, ll) = hill(case);
    let nx = 32usize << n;
    let mut nz = NZ0;
    for _ in 0..n {
        nz = 2 * nz - 1;
    }
    let dx = 400.0 / (1u64 << n) as f64;
    let dz = dx / 4.0;
    let z0 = -dz;
    let fine = 512usize;
    let per = fine / nx;
    let h: Vec<f32> = (0..nx)
        .map(|c| {
            (0..per)
                .map(|j| {
                    let x = -6400.0 + ((c * per + j) as f64 + 0.5) * 25.0;
                    hh / (1.0 + (x / ll) * (x / ll))
                })
                .fold(0.0f64, f64::max) as f32
        })
        .collect();
    let mut cell = vec![0u8; nz * nx];
    for k in 0..nz {
        for i in 0..nx {
            let zc = z0 + (k as f64 + 0.5) * dz;
            cell[k * nx + i] = u8::from(zc >= h[i] as f64);
        }
    }
    let air = |k: usize, i: usize| cell[k * nx + i] != 0;
    let mut tu = vec![0u8; nz * (nx + 1)];
    for k in 0..nz {
        for i in 0..=nx {
            let l = i == 0 || air(k, i - 1);
            let r = i == nx || air(k, i);
            tu[k * (nx + 1) + i] = u8::from(l && r);
        }
    }
    let mut tw = vec![0u8; (nz + 1) * nx];
    for k in 1..=nz {
        for i in 0..nx {
            let d = air(k - 1, i);
            let u = k == nz || air(k, i);
            tw[k * nx + i] = u8::from(d && u);
        }
    }
    let mut q = vec![0.0f32; nz * nx];
    if heated {
        for k in 0..nz {
            for i in 0..nx {
                if air(k, i) {
                    let x = -6400.0 + (i as f64 + 0.5) * dx;
                    let zagl = z0 + (k as f64 + 0.5) * dz - h[i] as f64;
                    q[k * nx + i] =
                        (2e-4 * (-zagl / 150.0).exp() * (0.6 + 0.4 * (x / 480.0).sin())) as f32;
                }
            }
        }
    }
    Geo {
        nx,
        nz,
        dx,
        dz,
        z0,
        cell,
        tu,
        tw,
        h,
        q,
    }
}

/// Divergence-free (exactly, by a stream function at the corners) field over the geometry:
/// u = dpsi/dz, w = -dpsi/dx, psi = dz*(u0*max(0, k - ground) + noise*eps*min(1, k - ground)). Zero on walls.
pub fn parent(g: &Geo, u0: f64, noise: f64, seed: u64) -> Level {
    let (nx, nz) = (g.nx, g.nz);
    let mut rng = Rng(seed);
    let ground: Vec<usize> = (0..nx)
        .map(|i| (0..nz).take_while(|&k| g.cell[k * nx + i] == 0).count())
        .collect();
    let node_g = |i: usize| -> usize {
        let l = if i > 0 { ground[i - 1] } else { 0 };
        let r = if i < nx { ground[i] } else { 0 };
        match (i > 0, i < nx) {
            (true, true) => l.max(r),
            (true, false) => l,
            _ => r,
        }
    };
    let mut psi = vec![0.0f64; (nz + 1) * (nx + 1)];
    for k in 0..=nz {
        for i in 0..=nx {
            let e = 2.0 * rng.unit() - 1.0;
            let lift = k.saturating_sub(node_g(i)) as f64;
            psi[k * (nx + 1) + i] = g.dz * (u0 * lift + noise * e * lift.min(1.0));
        }
    }
    let mut u = vec![0.0f32; nz * (nx + 1)];
    let mut w = vec![0.0f32; (nz + 1) * nx];
    for k in 0..nz {
        for i in 0..=nx {
            u[k * (nx + 1) + i] =
                ((psi[(k + 1) * (nx + 1) + i] - psi[k * (nx + 1) + i]) / g.dz) as f32;
        }
    }
    for k in 0..=nz {
        for i in 0..nx {
            w[k * nx + i] = (-(psi[k * (nx + 1) + i + 1] - psi[k * (nx + 1) + i]) / g.dx) as f32;
        }
    }
    let mut th = vec![0.0f32; nz * nx];
    for k in 0..nz {
        for i in 0..nx {
            let x = -6400.0 + (i as f64 + 0.5) * g.dx;
            let z = g.z0 + (k as f64 + 0.5) * g.dz;
            th[k * nx + i] = (0.8 * (x / 700.0).sin() * (-z / 800.0).exp()
                + 0.2 * (2.0 * rng.unit() - 1.0)) as f32;
        }
    }
    Level { nx, nz, u, w, th }
}
